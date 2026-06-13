//
//  OnboardingViewModel.swift
//  EarShot
//

import AppKit
import FluidAudio
import Foundation
import Observation

@MainActor
@Observable
final class OnboardingViewModel {
    enum Phase: Equatable {
        case welcome
        case microphone
        case modelDownload
        case enrollment
        case complete
    }

    enum DownloadState: Equatable {
        case idle
        case running(stage: ModelDownloader.Stage)
        case failed(message: String)
        case done
    }

    enum EnrollmentRunState: Equatable {
        case idle
        case starting
        case recording(secondsRemaining: Int)
        case extracting
        case failed(message: String)
        case done
    }

    // MARK: State
    var phase: Phase = .welcome
    var micState: MicrophoneAuthorization.State = MicrophoneAuthorization.currentState
    var downloadState: DownloadState = .idle
    var enrollmentState: EnrollmentRunState = .idle
    var ownerName: String = NSFullUserName().isEmpty ? "Me" : NSFullUserName()

    // MARK: Dependencies
    private let downloader = ModelDownloader()
    private let recorder = EnrollmentRecorder()
    private var loadedModels: ModelDownloader.Loaded?
    private let onFinished: () -> Void

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    // MARK: Welcome
    func continueFromWelcome() {
        phase = .microphone
        if micState == .granted {
            // Already granted on a prior launch; jump straight ahead.
            phase = .modelDownload
        }
    }

    // MARK: Microphone
    func requestMicrophone() async {
        micState = await MicrophoneAuthorization.request()
        if micState == .granted {
            phase = .modelDownload
        }
    }

    func openSystemSettingsForMicrophone() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Model download
    func startDownload() async {
        downloadState = .running(stage: .asr)
        do {
            let loaded = try await downloader.loadAll { [weak self] stage in
                guard let self else { return }
                self.downloadState = .running(stage: stage)
            }
            self.loadedModels = loaded
            self.downloadState = .done
            self.phase = .enrollment
        } catch {
            downloadState = .failed(message: error.localizedDescription)
        }
    }

    // MARK: Enrollment
    func startEnrollment() async {
        guard let models = loadedModels else {
            enrollmentState = .failed(message: "Models not loaded. Restart onboarding.")
            return
        }

        enrollmentState = .starting

        let diarizer = DiarizerManager()
        diarizer.initialize(models: models.diarizer)

        do {
            let samples = try await recorder.record(seconds: 30) { [weak self] remaining in
                self?.enrollmentState = .recording(secondsRemaining: remaining)
            }

            enrollmentState = .extracting

            let embedding = try diarizer.extractSpeakerEmbedding(from: samples)
            guard !embedding.isEmpty else {
                enrollmentState = .failed(message: "Voice embedding came back empty. Try a quieter room.")
                return
            }

            // Persist directly to the GRDB speaker library (S2). We still
            // write the .bin fallback so a fresh install from an older
            // backup that lacks the SQLite file can recover via the
            // migration path in `SpeakerLibrary.migrateOwnerEmbeddingFileIfNeeded`.
            let library = try SpeakerLibrary()
            let resolvedName = ownerName.isEmpty ? "Me" : ownerName
            _ = try await library.enrollOwner(name: resolvedName, embedding: embedding)
            try? saveOwnerEmbeddingFallback(embedding)
            AppSettings.ownerSpeakerID = "owner"

            enrollmentState = .done
            phase = .complete
        } catch {
            enrollmentState = .failed(message: error.localizedDescription)
        }
    }

    // MARK: Finish
    func finish() {
        AppSettings.onboardingCompleted = true
        onFinished()
    }

    /// Persists the embedding to the Chunk-2 `me_embedding.bin` so a future
    /// install that loses the SQLite DB (but kept Application Support)
    /// can recover via `SpeakerLibrary.migrateOwnerEmbeddingFileIfNeeded`.
    /// Best-effort — failures here do not block onboarding.
    private func saveOwnerEmbeddingFallback(_ embedding: [Float]) throws {
        let url = try AppSettings.ownerEmbeddingURL()
        let data = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url, options: .atomic)
    }
}
