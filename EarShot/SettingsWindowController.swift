//
//  SettingsWindowController.swift
//  EarShot
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
    }

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Build window first so we can pass it into the SwiftUI view; the
        // folder picker sheet-attaches to it instead of free-floating.
        let placeholder = NSHostingController(rootView: SettingsViewPlaceholder())
        let window = NSWindow(contentViewController: placeholder)
        window.title = "EarShot Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 580))
        window.center()

        let host = NSHostingController(rootView: SettingsView(model: model, hostWindow: window))
        window.contentViewController = host

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

/// Empty stand-in so the NSWindow has a content view controller before we
/// swap in the real one (which needs a reference back to the window).
private struct SettingsViewPlaceholder: View {
    var body: some View { Color.clear.frame(width: 520, height: 580) }
}
