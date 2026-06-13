//
//  LoginItem.swift
//  EarShot
//

import Foundation
import ServiceManagement
import os

/// Launch-at-login via `SMAppService.mainApp`. On macOS 13+, this is the
/// official replacement for hand-written LaunchAgent plists — the system
/// materializes the underlying LaunchAgent on our behalf when the app is
/// registered. The "LaunchAgent" line in CLAUDE.md's survival checklist
/// refers to the mechanism, and `SMAppService.mainApp` IS the modern API
/// for it on macOS 14.4+.
///
/// No entitlement is required. The app must live in /Applications (or a
/// signed location the system trusts) for registration to actually take
/// effect at the next login — during development the registration call
/// returns success but the agent won't fire until the build is moved.
@MainActor
enum LoginItem {
    private static let log = Logger(subsystem: "com.earshot.app", category: "LoginItem")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns true if the registration succeeded. False on any error; the
    /// reason is logged. We never throw from here — the launch-at-login
    /// preference is a nice-to-have and should not abort settings UI flows.
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            log.error("SMAppService.mainApp \(on ? "register" : "unregister") failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
