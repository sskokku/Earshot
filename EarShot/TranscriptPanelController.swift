//
//  TranscriptPanelController.swift
//  EarShot
//

import AppKit
import SwiftUI

@MainActor
final class TranscriptPanelController {
    private(set) var panel: TranscriptPanel?
    private let appState: AppState
    private var actions: PanelActions?

    init(appState: AppState) {
        self.appState = appState
    }

    /// Wired by AppDelegate after the speaker library is open. Until this
    /// is set the panel renders no-op actions; the rename / search /
    /// open-library buttons still appear but do nothing.
    func setActions(_ actions: PanelActions) {
        self.actions = actions
    }

    func toggle() {
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil {
            let initialFrame = NSRect(x: 0, y: 0, width: 460, height: 360)
            let hostingView = NSHostingView(rootView: TranscriptPanelView(
                appState: appState,
                actions: actions ?? Self.noopActions
            ))
            hostingView.frame = initialFrame
            let newPanel = TranscriptPanel(contentRect: initialFrame, contentView: hostingView)
            newPanel.center()
            panel = newPanel
        }
        panel?.orderFrontRegardless()
        appState.isPanelVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        appState.isPanelVisible = false
    }

    /// Placeholder actions used until AppDelegate finishes booting the
    /// speaker library + identity resolver. Selecting a rename action
    /// before that happens is a no-op rather than a crash.
    private static let noopActions = PanelActions(
        renameSpeaker: { _ in },
        openTranscriptSearch: { },
        openSpeakerLibrary: { }
    )
}
