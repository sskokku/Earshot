//
//  TranscriptPanel.swift
//  EarShot
//

import AppKit

/// Non-activating, always-on-top transcript panel.
///
/// CLAUDE.md rule 10: `sharingType == .none` is a hard requirement so the panel is
/// invisible to screen shares and recordings. Covered by a unit test.
final class TranscriptPanel: NSPanel {
    init(contentRect: NSRect, contentView: NSView) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )

        sharingType = .none

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        title = "EarShot"
        titleVisibility = .visible
        minSize = NSSize(width: 320, height: 220)

        // Liquid Glass: clear the panel's own backing so SwiftUI's
        // `.glassEffect` chrome inside renders without a competing fill.
        // Rule 10 invariants above (sharingType = .none, .nonactivatingPanel,
        // sharing behavior) are unaffected by these two property writes.
        isOpaque = false
        backgroundColor = .clear

        self.contentView = contentView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
