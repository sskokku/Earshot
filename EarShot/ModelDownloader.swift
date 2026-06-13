//
//  ModelDownloader.swift
//  EarShot
//

import Foundation
import FluidAudio

/// Orchestrates the first-run download of the FluidAudio model bundles.
///
/// "Resume" is provided by FluidAudio itself: each `downloadAndLoad` /
/// `downloadIfNeeded` call uses the cache at
/// `~/Library/Application Support/FluidAudio/Models/<repo>` and skips bundles
/// already on disk. Reinvoking after a failure picks up where it left off.
@MainActor
final class ModelDownloader {
    struct Loaded {
        let asr: AsrModels
        let diarizer: DiarizerModels
        let vad: VadManager
    }

    enum Stage: Equatable {
        case asr
        case diarizer
        case vad
    }

    enum DownloadError: LocalizedError {
        case stage(Stage, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .stage(.asr, let e):
                return "Speech recognition model failed to load: \(e.localizedDescription)"
            case .stage(.diarizer, let e):
                return "Diarization model failed to load: \(e.localizedDescription)"
            case .stage(.vad, let e):
                return "Voice activity model failed to load: \(e.localizedDescription)"
            }
        }
    }

    func loadAll(progress: @MainActor @escaping (Stage) -> Void) async throws -> Loaded {
        progress(.asr)
        let asr: AsrModels
        do {
            asr = try await AsrModels.downloadAndLoad(version: .v3)
        } catch {
            throw DownloadError.stage(.asr, underlying: error)
        }

        progress(.diarizer)
        let diarizer: DiarizerModels
        do {
            diarizer = try await DiarizerModels.downloadIfNeeded()
        } catch {
            throw DownloadError.stage(.diarizer, underlying: error)
        }

        progress(.vad)
        let vad: VadManager
        do {
            vad = try await VadManager()
        } catch {
            throw DownloadError.stage(.vad, underlying: error)
        }

        return Loaded(asr: asr, diarizer: diarizer, vad: vad)
    }
}
