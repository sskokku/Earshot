//
//  MenuBarContent.swift
//  EarShot
//

import SwiftUI

struct MenuBarContent: View {
    @Bindable var appState: AppState
    let panelController: TranscriptPanelController
    let settingsController: SettingsWindowController
    let onTogglePause: () -> Void
    let onDumpSpeakers: () -> Void
    let onOpenSpeakerLibrary: () -> Void
    let onOpenTranscriptSearch: () -> Void
    let onOpenTimeline: () -> Void
    let onOpenSpeakerCuration: () -> Void

    var body: some View {
        Text(statusLine)

        Divider()

        Button(appState.isPanelVisible ? "Hide Transcript Panel" : "Show Transcript Panel") {
            panelController.toggle()
        }
        .keyboardShortcut("p")

        Button(pauseTitle) {
            onTogglePause()
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(!canTogglePause)

        Divider()

        Button(needsNamingTitle) {
            onOpenSpeakerCuration()
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])

        Button("Speakers…") {
            onOpenSpeakerLibrary()
        }
        .keyboardShortcut("k", modifiers: [.command, .shift])

        Button("Search Transcripts…") {
            onOpenTranscriptSearch()
        }
        .keyboardShortcut("f", modifiers: [.command])

        Button("Timeline…") {
            onOpenTimeline()
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])

        Button("Settings…") {
            settingsController.show()
        }
        .keyboardShortcut(",")

        Divider()

        // Debug: show speakers + embedding counts so chunk S2's enrollment
        // and per-segment storage can be verified without opening sqlite3.
        Button("Dump Speaker Library…") {
            onDumpSpeakers()
        }

        Divider()

        Button("Quit EarShot") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        if appState.unnamedSpeakerCount > 0 {
            return "EarShot — \(appState.status.label) · \(appState.unnamedSpeakerCount) to name"
        }
        return "EarShot — \(appState.status.label)"
    }

    private var needsNamingTitle: String {
        if appState.unnamedSpeakerCount > 0 {
            return "Needs Naming (\(appState.unnamedSpeakerCount))…"
        }
        return "Needs Naming…"
    }

    private var pauseTitle: String {
        switch appState.status {
        case .paused: return "Resume Listening"
        case .listening: return "Pause Listening"
        case .idle: return "Pause Listening"
        case .error: return "Pause Listening"
        }
    }

    private var canTogglePause: Bool {
        switch appState.status {
        case .listening, .paused: return true
        case .idle, .error: return false
        }
    }
}
