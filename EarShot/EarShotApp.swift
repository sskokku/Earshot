//
//  EarShotApp.swift
//  EarShot
//

import SwiftUI

@main
struct EarShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                appState: appDelegate.appState,
                panelController: appDelegate.panelController,
                settingsController: appDelegate.settingsController,
                onTogglePause: { appDelegate.togglePause() },
                onDumpSpeakers: { appDelegate.showSpeakerLibraryDump() },
                onOpenSpeakerLibrary: { appDelegate.showSpeakerLibraryWindow() },
                onOpenTranscriptSearch: { appDelegate.showTranscriptSearchWindow() },
                onOpenTimeline: { appDelegate.showTimelineWindow() },
                onOpenSpeakerCuration: { appDelegate.showSpeakerCurationWindow() }
            )
        } label: {
            // `.menuBarExtraStyle(.menu)` expects the label closure to
            // resolve to a stable, image-shaped view. Wrapping it in a
            // custom View with an `.overlay { Capsule … }` ran the system
            // into a layout loop that beachballed the app at boot — even
            // when the overlay would have been hidden. Keep the label a
            // plain Image; the unnamed-speaker count is surfaced as a
            // textual badge inside the menu's top status line and on the
            // "Needs Naming (N)…" item.
            Image(systemName: appDelegate.appState.status.systemImageName)
                .accessibilityLabel(menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarAccessibilityLabel: String {
        let state = appDelegate.appState
        if state.unnamedSpeakerCount > 0 {
            return "EarShot — \(state.status.label), \(state.unnamedSpeakerCount) to name"
        }
        return "EarShot — \(state.status.label)"
    }
}
