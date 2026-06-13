//
//  ConsentGate.swift
//  EarShot
//

import AppKit
import SwiftUI

/// First-launch consent + informed-use gate. Mirrors `OnboardingWindowController`
/// in shape but runs BEFORE onboarding so no audio capture path can start
/// until the user has explicitly accepted responsibility for recording and
/// wiretapping compliance in their jurisdiction. Persists acceptance in
/// `AppSettings.consentAccepted` so subsequent launches skip the gate.
///
/// PLACEHOLDER legal wording — see `ConsentText.full` and review with
/// counsel before publishing.
@MainActor
final class ConsentGateController {
    private var window: NSWindow?

    /// Returns true if the gate is required and was shown.
    @discardableResult
    func presentIfNeeded(onAccepted: @escaping () -> Void) -> Bool {
        guard !AppSettings.consentAccepted else { return false }
        present(onAccepted: onAccepted)
        return true
    }

    private func present(onAccepted: @escaping () -> Void) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(
            rootView: ConsentGateView(
                onAccept: { [weak self] in
                    AppSettings.consentAccepted = true
                    self?.dismiss()
                    onAccepted()
                },
                onQuit: {
                    NSApp.terminate(nil)
                }
            )
        )
        let window = NSWindow(contentViewController: host)
        window.title = "EarShot — Recording Consent"
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func dismiss() {
        window?.close()
        window = nil
    }
}

struct ConsentGateView: View {
    let onAccept: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Before EarShot can listen")
                    .font(.title2).bold()
                Text("Please read and accept the recording consent and disclaimer.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                ScrollView {
                    Text(ConsentText.full)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }
                .frame(maxHeight: .infinity)
            }

            HStack {
                Button("Quit") { onQuit() }
                Spacer()
                Button("I Accept") { onAccept() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
    }
}

/// Canonical consent text. Rendered both in the first-launch gate and in
/// Settings (so the user can re-read it any time). One source of truth so
/// the two surfaces never drift.
///
/// PLACEHOLDER - REVIEW WITH COUNSEL before publishing.
enum ConsentText {
    static let full: String = """
    EarShot Recording Consent & Disclaimer

    What EarShot does
    EarShot is an always-on transcription tool that runs on your Mac. While it is
    listening, it captures audio from your microphone and, with your separate
    permission, from other applications running on this Mac (for example, video
    conferencing apps). It converts that audio to text on-device and stores the
    text on your Mac. EarShot does not upload audio or transcripts to any server.

    What EarShot cannot do for you
    EarShot does not know who is in the room with you. It does not know whether
    the people on the other end of a video call have agreed to be recorded or
    transcribed. It does not know what jurisdiction you are in.

    Your responsibility
    Recording, transcribing, or otherwise capturing conversations — including
    your own — is regulated by law in many places. Some U.S. states and many
    countries require the consent of every participant in a conversation before
    any recording or transcription may take place. Others require the consent
    of only one participant. Some prohibit recording in specific settings
    regardless of consent. Workplace, healthcare, education, and legal contexts
    often have additional rules on top of general recording law.

    By accepting this notice you confirm that:
      1. You understand EarShot will continuously capture microphone audio and
         any system audio you separately authorize, and convert it to a
         stored on-device transcript.
      2. You are solely responsible for knowing and complying with all
         applicable laws and policies in every jurisdiction where you use
         EarShot, including but not limited to wiretapping, eavesdropping,
         two-party consent, one-party consent, workplace surveillance,
         student-privacy, patient-privacy, and professional-conduct rules.
      3. You will obtain any consent required by those laws or policies from
         every person whose voice EarShot may capture, before EarShot captures
         their voice.
      4. You will not use EarShot to record any conversation where doing so
         would be unlawful, against the policy of your employer, school, or
         professional body, or against the expressed wishes of a participant.
      5. You accept all risk arising from your use of EarShot. The author of
         EarShot provides this software as-is, with no warranty, and accepts
         no liability for your use of it.

    EarShot will not begin capturing audio until you accept this notice.
    You can re-read it any time in Settings.
    """
}
