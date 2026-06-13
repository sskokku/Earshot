//
//  OnboardingView.swift
//  EarShot
//

import SwiftUI

struct OnboardingView: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(28)
        .frame(width: 560, height: 440)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome to EarShot")
                .font(.title2).bold()
            Text(phaseSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chromeSurface(cornerRadius: 12)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .welcome:
            welcomeContent
        case .microphone:
            microphoneContent
        case .modelDownload:
            downloadContent
        case .enrollment:
            enrollmentContent
        case .complete:
            completeContent
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            switch viewModel.phase {
            case .welcome:
                Button("Continue") { viewModel.continueFromWelcome() }
                    .keyboardShortcut(.defaultAction)
            case .microphone:
                microphoneFooter
            case .modelDownload:
                downloadFooter
            case .enrollment:
                enrollmentFooter
            case .complete:
                Button("Finish") { viewModel.finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Welcome
    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Always-on, on-device transcription.", systemImage: "ear.fill")
            Label("Identifies speakers by voice and remembers them.", systemImage: "person.2.wave.2.fill")
            Label("Audio never leaves this Mac.", systemImage: "lock.shield.fill")
            Spacer(minLength: 12)
            Text("Three quick steps before we listen: microphone access, a one-time model download (about 1 GB), and a 30-second voice sample so we recognize you.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Microphone
    private var microphoneContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("EarShot needs microphone access to transcribe what it hears.")
            switch viewModel.micState {
            case .unknown:
                Text("Click Grant Access to show the macOS permission prompt.")
                    .foregroundStyle(.secondary)
            case .granted:
                Label("Microphone access granted.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .denied:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Microphone access denied.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text("Open System Settings → Privacy & Security → Microphone and turn EarShot on, then come back.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var microphoneFooter: some View {
        switch viewModel.micState {
        case .unknown:
            Button("Grant Access") {
                Task { await viewModel.requestMicrophone() }
            }
            .keyboardShortcut(.defaultAction)
        case .granted:
            Button("Continue") { viewModel.phase = .modelDownload }
                .keyboardShortcut(.defaultAction)
        case .denied:
            Button("Open System Settings") { viewModel.openSystemSettingsForMicrophone() }
            Button("Re-check") {
                viewModel.micState = MicrophoneAuthorization.currentState
                if viewModel.micState == .granted { viewModel.phase = .modelDownload }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Download
    private var downloadContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Downloading on-device models from HuggingFace. This happens once — about 1 GB total. If the connection drops, the next attempt resumes from where it left off.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                downloadRow(.asr, label: "Speech recognition (Parakeet TDT v3)", sizeHint: "~600 MB")
                downloadRow(.diarizer, label: "Speaker diarization (Pyannote + WeSpeaker)", sizeHint: "~250 MB")
                downloadRow(.vad, label: "Voice activity detection (Silero)", sizeHint: "~3 MB")
            }

            if case .failed(let message) = viewModel.downloadState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func downloadRow(_ stage: ModelDownloader.Stage, label: String, sizeHint: String) -> some View {
        HStack(spacing: 10) {
            statusIcon(for: stage)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(sizeHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func statusIcon(for stage: ModelDownloader.Stage) -> some View {
        switch viewModel.downloadState {
        case .idle:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .running(let current):
            if current == stage {
                ProgressView().controlSize(.small)
            } else if stageIndex(current) > stageIndex(stage) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: "circle").foregroundStyle(.tertiary)
            }
        case .failed:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private func stageIndex(_ stage: ModelDownloader.Stage) -> Int {
        switch stage {
        case .asr: return 0
        case .diarizer: return 1
        case .vad: return 2
        }
    }

    @ViewBuilder
    private var downloadFooter: some View {
        switch viewModel.downloadState {
        case .idle:
            Button("Start Download") {
                Task { await viewModel.startDownload() }
            }
            .keyboardShortcut(.defaultAction)
        case .running:
            Button("Downloading…") {}
                .disabled(true)
        case .failed:
            Button("Retry") {
                Task { await viewModel.startDownload() }
            }
            .keyboardShortcut(.defaultAction)
        case .done:
            Button("Continue") { viewModel.phase = .enrollment }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Enrollment
    private var enrollmentContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Your name", text: $viewModel.ownerName)
                .textFieldStyle(.roundedBorder)
                .disabled(isEnrollmentBusy)

            Text("Read the paragraph below in a normal voice for 30 seconds. EarShot uses this sample to recognize you in future transcripts. The audio is not saved — only the voice fingerprint.")
                .foregroundStyle(.secondary)

            GroupBox {
                ScrollView {
                    Text(enrollmentScript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .frame(maxHeight: 140)
            }

            enrollmentStatus
        }
    }

    private var enrollmentScript: String {
        """
        The rain in the harbor came in slow, even sheets, and the gulls were quiet for once. I watched the fishing boats drift toward their slips, lined up like commas at the end of long sentences. In the distance, a foghorn answered itself across the water. \
        I like reading aloud because it makes me notice the shape of words — the round, low ones, the bright, fast ones, and the ones that slow you down because they almost rhyme. When the wind picks up later, it will smell like cedar smoke from the cabins inland.
        """
    }

    @ViewBuilder
    private var enrollmentStatus: some View {
        switch viewModel.enrollmentState {
        case .idle:
            Text("Press Start when ready.")
                .foregroundStyle(.secondary)
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Warming up the microphone…").foregroundStyle(.secondary)
            }
        case .recording(let remaining):
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(.red)
                Text("Recording — \(remaining)s remaining")
            }
        case .extracting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Computing voice fingerprint…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .done:
            Label("Got it.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private var isEnrollmentBusy: Bool {
        switch viewModel.enrollmentState {
        case .starting, .recording, .extracting: return true
        default: return false
        }
    }

    @ViewBuilder
    private var enrollmentFooter: some View {
        switch viewModel.enrollmentState {
        case .idle, .failed:
            Button("Start Recording") {
                Task { await viewModel.startEnrollment() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(viewModel.ownerName.trimmingCharacters(in: .whitespaces).isEmpty)
        case .starting, .recording, .extracting:
            Button("Recording…") {}
                .disabled(true)
        case .done:
            Button("Continue") { viewModel.phase = .complete }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Complete
    private var completeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Setup complete.", systemImage: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(.green)
            Text("EarShot will appear in your menu bar. Click the ear icon any time to show or hide the live transcript panel. The transcription pipeline lands in the next chunk.")
                .foregroundStyle(.secondary)
        }
    }

    private var phaseSubtitle: String {
        switch viewModel.phase {
        case .welcome: return "Let's get you set up."
        case .microphone: return "Step 1 of 3 — Microphone access"
        case .modelDownload: return "Step 2 of 3 — Download speech models"
        case .enrollment: return "Step 3 of 3 — Recognize your voice"
        case .complete: return "You're all set."
        }
    }
}
