//
//  AppSettings.swift
//  EarShot
//

import Foundation

/// First-run state and on-disk paths. UserDefaults for booleans/strings,
/// Application Support directory for binary artifacts like the owner embedding.
///
/// Everything here is `nonisolated` so the GRDB-backed SpeakerLibrary actor
/// (and any other off-main-actor caller) can resolve owner state without
/// hopping to MainActor. UserDefaults is already thread-safe.
nonisolated enum AppSettings {
    private static let onboardingCompletedKey = "earshot.onboardingCompleted"
    private static let consentAcceptedKey = "earshot.consentAccepted"
    private static let ownerNameKey = "earshot.ownerName"
    private static let ownerSpeakerIDKey = "earshot.ownerSpeakerID"
    private static let transcriptsFolderKey = "earshot.transcriptsFolder"

    static var onboardingCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: onboardingCompletedKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardingCompletedKey) }
    }

    /// First-launch consent gate (`ConsentGate.swift`). Must be `true` before
    /// any audio capture path can start. The gate writes `true` only after
    /// the user clicks "I Accept" on the modal carrying `ConsentText.full`.
    static var consentAccepted: Bool {
        get { UserDefaults.standard.bool(forKey: consentAcceptedKey) }
        set { UserDefaults.standard.set(newValue, forKey: consentAcceptedKey) }
    }

    static var ownerName: String? {
        get { UserDefaults.standard.string(forKey: ownerNameKey) }
        set { UserDefaults.standard.set(newValue, forKey: ownerNameKey) }
    }

    static var ownerSpeakerID: String? {
        get { UserDefaults.standard.string(forKey: ownerSpeakerIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: ownerSpeakerIDKey) }
    }

    /// Persistent SQLite primary key for the owner's speaker row. Distinct
    /// from `ownerSpeakerID` (a Chunk-2-era opaque string) because S2's
    /// SpeakerLibrary needs an Int64 to bind to the GRDB schema.
    static var ownerSpeakerIDValue: Int64? {
        get {
            let v = UserDefaults.standard.object(forKey: ownerSpeakerIDValueKey) as? NSNumber
            return v?.int64Value
        }
        set {
            if let newValue {
                UserDefaults.standard.set(NSNumber(value: newValue), forKey: ownerSpeakerIDValueKey)
            } else {
                UserDefaults.standard.removeObject(forKey: ownerSpeakerIDValueKey)
            }
        }
    }
    private static let ownerSpeakerIDValueKey = "earshot.ownerSpeakerIDValue"

    /// Folder where daily Markdown transcripts are written. Default lives in
    /// the user's home, not Application Support, because PRD R5 says the user
    /// can swap it for any folder (iCloud Drive, external disk, etc.) and the
    /// path should be human-discoverable.
    static var transcriptsFolder: URL {
        get {
            if let stored = UserDefaults.standard.string(forKey: transcriptsFolderKey),
               !stored.isEmpty {
                return URL(fileURLWithPath: (stored as NSString).expandingTildeInPath, isDirectory: true)
            }
            return defaultTranscriptsFolder
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: transcriptsFolderKey)
        }
    }

    static var defaultTranscriptsFolder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Earshot/transcripts", isDirectory: true)
    }

    /// H1 — PRD R8 "logged to ~/Earshot/logs/". Daily-rotated event log,
    /// separate from the Markdown transcript and the .metrics.json sidecar.
    /// `FileLogger` creates the directory on first write; we do not gate
    /// behind sandbox permissions because this lives under `~/Earshot/`
    /// which the user already owns via the transcript folder choice.
    static var logsFolder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Earshot/logs", isDirectory: true)
    }

    // MARK: - H1 crash-recovery lifecycle flag

    /// Set on `applicationDidFinishLaunching`, cleared in
    /// `cleanupForTermination`. On the next launch, if it's still set,
    /// the previous process did not exit cleanly — we write a
    /// `recovered HH:MM:SS` marker into today's transcript so a human
    /// reader can see where the prior session ended. CLAUDE.md rule 4
    /// (append-only) means we never need to repair the file itself; the
    /// marker is purely informational.
    private static let runningSessionFlagKey = "earshot.runningSessionFlag"
    private static let runningSessionStartedAtKey = "earshot.runningSessionStartedAt"

    static var runningSessionFlag: Bool {
        get { UserDefaults.standard.bool(forKey: runningSessionFlagKey) }
        set { UserDefaults.standard.set(newValue, forKey: runningSessionFlagKey) }
    }

    static var runningSessionStartedAt: Date? {
        get {
            let v = UserDefaults.standard.object(forKey: runningSessionStartedAtKey) as? Date
            return v
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: runningSessionStartedAtKey)
            } else {
                UserDefaults.standard.removeObject(forKey: runningSessionStartedAtKey)
            }
        }
    }

    /// H1 — debug "soak mode" toggle. Activated via the launch argument
    /// `-EarShotSoakMode YES` (which `UserDefaults.standard` auto-binds
    /// into the NSArgumentDomain) or by setting the user-defaults key
    /// directly with `defaults write com.earshot.app EarShotSoakMode -bool true`.
    /// When on, `SoakHarness` boots after the pipelines and starts
    /// injecting synthetic audio + writing a per-minute soak log.
    static var soakModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "EarShotSoakMode")
    }

    /// Ensures `~/Library/Application Support/EarShot/` exists and returns its URL.
    /// In a sandboxed build this resolves to the per-container path.
    static func supportDirectory() throws -> URL {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "EarShot.AppSettings",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No Application Support directory found."]
            )
        }
        let dir = base.appendingPathComponent("EarShot", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func ownerEmbeddingURL() throws -> URL {
        try supportDirectory().appendingPathComponent("me_embedding.bin")
    }

    /// Canonical path to the SQLite speaker library backing the S2 schema.
    static func speakerLibraryURL() throws -> URL {
        try supportDirectory().appendingPathComponent("speaker_library.sqlite3")
    }
}
