//
//  AppState.swift
//  EarShot
//

import SwiftUI

@MainActor
@Observable
final class AppState {
    enum Status {
        case idle
        case listening
        case paused
        case error

        var systemImageName: String {
            switch self {
            case .idle: return "ear"
            case .listening: return "ear.fill"
            case .paused: return "pause.circle"
            case .error: return "exclamationmark.triangle"
            }
        }

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .listening: return "Listening"
            case .paused: return "Paused"
            case .error: return "Error"
            }
        }
    }

    var status: Status = .idle
    var isPanelVisible: Bool = false
    var lastErrorMessage: String?

    /// CLAUDE.md "Metrics and errors" §: glyph error state only after N
    /// consecutive failed recoveries. The counter resets to 0 on any return
    /// to `.listening`; only at `consecutiveRecoveryFailures >= errorGlyphThreshold`
    /// does the visible status flip to `.error`.
    let errorGlyphThreshold: Int = 3
    private(set) var consecutiveRecoveryFailures: Int = 0

    /// Source of truth for what the floating panel renders.
    let transcript = LiveTranscript()

    func noteRecoverySucceeded() {
        consecutiveRecoveryFailures = 0
    }

    /// Returns true if the counter has reached the glyph-error threshold —
    /// AppDelegate uses this to decide whether to flip `status` to `.error`.
    @discardableResult
    func noteRecoveryFailed() -> Bool {
        consecutiveRecoveryFailures += 1
        return consecutiveRecoveryFailures >= errorGlyphThreshold
    }
}
