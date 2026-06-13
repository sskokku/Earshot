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
                onOpenTimeline: { appDelegate.showTimelineWindow() }
            )
        } label: {
            Image(systemName: appDelegate.appState.status.systemImageName)
                .accessibilityLabel("EarShot — \(appDelegate.appState.status.label)")
        }
        .menuBarExtraStyle(.menu)
    }
}
