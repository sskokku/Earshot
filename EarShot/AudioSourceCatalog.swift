//
//  AudioSourceCatalog.swift
//  EarShot
//

import AppKit
import CoreAudio
import Foundation

/// Builds the per-app catalog shown in Settings → Audio Sources.
///
/// PRD R2: "The list is built dynamically from NSWorkspace running
/// applications (apps currently producing audio surfaced first), with a
/// toggle per app, persisted in settings."
///
/// Two sources combined and deduped by bundle ID:
///   1. `HALAudioProcessLister` — the audio HAL's view of who currently has
///      the output path open. Surfaces helper / renderer PIDs (Teams2
///      renderer, Zoom helpers) so audio-active apps land at the top of
///      the list.
///   2. `NSWorkspace.runningApplications` — every regular foreground app.
///      Filtered to entries with a bundle ID so we have a stable key to
///      persist against.
///
/// Helper bundle IDs are collapsed to their parent (e.g.
/// `com.microsoft.teams2.notification` → `com.microsoft.teams2`) so the user
/// sees one toggle for "Microsoft Teams" instead of three rows for its
/// helpers.
@MainActor
enum AudioSourceCatalog {

    struct Source: Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let displayName: String
        let isProducingAudio: Bool
    }

    /// Snapshot the current catalog. Cheap enough to call every couple of
    /// seconds from a settings-window refresh timer.
    static func enumerate() -> [Source] {
        var rows: [String: Source] = [:]

        let halProcesses = HALAudioProcessLister.enumerate()
        for proc in halProcesses {
            guard proc.isRunning, let bid = proc.bundleID, !bid.isEmpty else { continue }
            let parent = parentBundleID(for: bid)
            let nsApp = NSRunningApplication(processIdentifier: proc.pid)
            let display = displayName(forBundleID: parent, fallback: nsApp?.localizedName ?? parent)
            rows[parent] = Source(
                bundleID: parent,
                displayName: display,
                isProducingAudio: true
            )
        }

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bid = app.bundleIdentifier,
                  !bid.isEmpty else { continue }
            let parent = parentBundleID(for: bid)
            if rows[parent] != nil { continue }
            let display = displayName(forBundleID: parent, fallback: app.localizedName ?? parent)
            rows[parent] = Source(
                bundleID: parent,
                displayName: display,
                isProducingAudio: false
            )
        }

        // Surface seeded entries even when no process is running, so the
        // user can toggle them off before the next call begins.
        for seed in SystemAudioAllowlist.wellKnownSeeds where rows[seed.bundleID] == nil {
            rows[seed.bundleID] = Source(
                bundleID: seed.bundleID,
                displayName: seed.displayName,
                isProducingAudio: false
            )
        }

        return rows.values.sorted { a, b in
            if a.isProducingAudio != b.isProducingAudio { return a.isProducingAudio }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    /// Collapse helper bundle IDs to their parent for user-facing toggles.
    private static func parentBundleID(for bundleID: String) -> String {
        for seed in SystemAudioAllowlist.wellKnownSeeds {
            if bundleID == seed.bundleID || bundleID.hasPrefix(seed.bundleID + ".") {
                return seed.bundleID
            }
        }
        return bundleID
    }

    private static func displayName(forBundleID bundleID: String, fallback: String) -> String {
        for seed in SystemAudioAllowlist.wellKnownSeeds where seed.bundleID == bundleID {
            return seed.displayName
        }
        return fallback
    }

    /// Resolve an app icon for display in the settings list. Returns nil if
    /// no running app provides one; UI falls back to a generic SF Symbol.
    static func icon(forBundleID bundleID: String) -> NSImage? {
        for app in NSWorkspace.shared.runningApplications {
            if app.bundleIdentifier == bundleID, let icon = app.icon {
                return icon
            }
        }
        return nil
    }
}
