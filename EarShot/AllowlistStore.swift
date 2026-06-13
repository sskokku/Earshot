//
//  AllowlistStore.swift
//  EarShot
//

import Foundation

/// PRD R2: per-app allowlist controlling which apps' audio is captured by
/// the system-audio pipeline. Default-deny — a bundle ID that is not
/// present in the persisted map is never tapped.
///
/// Persistence: `UserDefaults` dictionary keyed by bundle ID. First read
/// seeds Microsoft Teams (new) and Zoom as enabled so the upgrade from
/// Phase 2 / C1's hard-coded list is a no-op for an existing install. After
/// that, the persisted map is authoritative: toggling Teams off durably
/// removes it from capture, even on the next launch.
///
/// Notifications: `allowlistChangedNotification` fires on every write. The
/// `SystemAudioPipeline` observes this and re-runs its tap-target poll
/// immediately so a meeting in progress switches off mid-call when the user
/// flips a toggle.
///
/// Members are `nonisolated` because the project's default actor isolation
/// is `MainActor`, but this store is read from the `SystemAudioPipeline`
/// actor and from `@Sendable` closures — neither of which is MainActor.
/// `UserDefaults` and `NotificationCenter` are both thread-safe, so the
/// nonisolated annotation is safe.
nonisolated enum SystemAudioAllowlist {
    private static let defaultsKey = "earshot.systemAudioAllowlist.enabled"
    private static let seededKey = "earshot.systemAudioAllowlist.seeded"

    static let allowlistChangedNotification = Notification.Name("earshot.systemAudioAllowlist.changed")

    /// Bundle IDs whose audio is currently allowed. Default-deny: any app
    /// NOT in this set is blocked.
    static func enabledBundleIDs() -> Set<String> {
        seedIfNeeded()
        let dict = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Bool]) ?? [:]
        return Set(dict.compactMap { $0.value ? $0.key : nil })
    }

    static func isEnabled(bundleID: String) -> Bool {
        enabledBundleIDs().contains(bundleID)
    }

    static func setEnabled(bundleID: String, enabled: Bool) {
        seedIfNeeded()
        var dict = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Bool]) ?? [:]
        if enabled {
            dict[bundleID] = true
        } else {
            // Remove rather than write false so default-deny stays a clean
            // "absent = off" invariant. The seeded flag prevents future
            // re-seeding from overwriting this choice.
            dict.removeValue(forKey: bundleID)
        }
        UserDefaults.standard.set(dict, forKey: defaultsKey)
        NotificationCenter.default.post(name: allowlistChangedNotification, object: nil)
    }

    /// One-shot seed of the well-known meeting apps. Skipped on every
    /// subsequent launch so a user-disabled app stays disabled.
    private static func seedIfNeeded() {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: seededKey) else { return }
        var dict = (ud.dictionary(forKey: defaultsKey) as? [String: Bool]) ?? [:]
        for seed in defaultSeededBundleIDs where dict[seed] == nil {
            dict[seed] = true
        }
        ud.set(dict, forKey: defaultsKey)
        ud.set(true, forKey: seededKey)
    }

    static let defaultSeededBundleIDs: [String] = [
        "com.microsoft.teams2",
        "us.zoom.xos",
    ]

    /// Well-known apps with helper-process matching hints. The HAL surfaces
    /// audio under helper bundle IDs for some Electron-style apps (Teams'
    /// `com.microsoft.WebKit.GPU` named "Microsoft Teams Graphics and
    /// Media", for example). Without a name-contains hint those helpers
    /// slip past a bundle-prefix-only matcher.
    struct WellKnownSeed: Sendable, Hashable {
        let bundleID: String
        let displayName: String
        let nameContains: [String]
    }

    static let wellKnownSeeds: [WellKnownSeed] = [
        WellKnownSeed(
            bundleID: "com.microsoft.teams2",
            displayName: "Microsoft Teams",
            nameContains: ["microsoft teams"]
        ),
        WellKnownSeed(
            bundleID: "us.zoom.xos",
            displayName: "Zoom",
            nameContains: ["zoom"]
        ),
    ]

    /// Build the `[SystemAudioPipeline.AllowlistEntry]` derived from the
    /// currently-enabled bundle IDs. For well-known apps we attach the
    /// helper-name hint; otherwise we use bundle-prefix matching only.
    static func currentEntries() -> [SystemAudioPipeline.AllowlistEntry] {
        let enabled = enabledBundleIDs()
        let seedMap = Dictionary(uniqueKeysWithValues: wellKnownSeeds.map { ($0.bundleID, $0) })
        return enabled.sorted().map { bid in
            if let seed = seedMap[bid] {
                return SystemAudioPipeline.AllowlistEntry(
                    bundleIDPrefixes: [seed.bundleID],
                    nameContains: seed.nameContains,
                    displayName: seed.displayName,
                    isLegacy: false
                )
            }
            return SystemAudioPipeline.AllowlistEntry(
                bundleIDPrefixes: [bid],
                nameContains: [],
                displayName: bid,
                isLegacy: false
            )
        }
    }
}
