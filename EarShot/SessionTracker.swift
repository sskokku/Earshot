//
//  SessionTracker.swift
//  EarShot
//

import Foundation
import os

/// Coordinates the live session lifecycle on top of `SpeakerLibrary`.
///
/// On boot the tracker closes any rows left open by a prior process
/// crash (the v4 migration only seeded historical (source, session_id)
/// groups from segments; runtime-opened rows whose pipeline stop never
/// landed are closed here with ended_at = now). After that it watches
/// mic + system pipeline status events and opens/closes one ambient
/// row per mic stretch and one call row per attached-tap stretch. The
/// two are independent — both can be open concurrently, mirroring the
/// two-pipeline model from rule 1.
///
/// Bookmark drops route through `recordBookmark`, which delegates to
/// `SpeakerLibrary.addBookmark` (attach to open session or mint a fresh
/// ambient one with the bookmark's label).
actor SessionTracker {
    private let library: SpeakerLibrary
    private let log = Logger(subsystem: "com.earshot.app", category: "SessionTracker")

    private var ambientSessionID: Int64?
    private var callSessionID: Int64?

    init(library: SpeakerLibrary) {
        self.library = library
    }

    /// One-time boot. Closes orphans, resets in-memory state. Safe to
    /// call repeatedly though only the first call matters in practice
    /// (subsequent calls would re-close already-closed rows, which is
    /// a no-op).
    func boot() async {
        do {
            try await library.closeOrphanedOpenSessions()
        } catch {
            log.error("closeOrphanedOpenSessions failed: \(error.localizedDescription, privacy: .public)")
        }
        ambientSessionID = nil
        callSessionID = nil
    }

    func micStarted(at when: Date = Date()) async {
        guard ambientSessionID == nil else { return }
        do {
            let id = try await library.openSession(
                type: .ambient,
                source: .mic,
                label: nil,
                startedAt: when
            )
            ambientSessionID = id
            log.info("Opened ambient session id=\(id)")
        } catch {
            log.error("openSession (ambient) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func micStopped(at when: Date = Date()) async {
        guard let id = ambientSessionID else { return }
        ambientSessionID = nil
        do {
            try await library.closeSession(id: id, endedAt: when)
            log.info("Closed ambient session id=\(id)")
        } catch {
            log.error("closeSession (ambient id=\(id)) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func systemStarted(at when: Date = Date()) async {
        guard callSessionID == nil else { return }
        do {
            let id = try await library.openSession(
                type: .call,
                source: .system,
                label: nil,
                startedAt: when
            )
            callSessionID = id
            log.info("Opened call session id=\(id)")
        } catch {
            log.error("openSession (call) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func systemStopped(at when: Date = Date()) async {
        guard let id = callSessionID else { return }
        callSessionID = nil
        do {
            try await library.closeSession(id: id, endedAt: when)
            log.info("Closed call session id=\(id)")
        } catch {
            log.error("closeSession (call id=\(id)) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drop a bookmark. The library handles the attach-vs-mint decision.
    /// If a new ambient session was minted (no pipeline was active at
    /// the moment) and we don't already have an ambient session id
    /// tracked, adopt the new row so the next mic-stopped will close it.
    @discardableResult
    func recordBookmark(label: String, at when: Date = Date()) async throws -> SpeakerLibrary.BookmarkOutcome {
        let outcome = try await library.addBookmark(label: label, capturedAt: when)
        if outcome.createdSession, outcome.session.source == .mic, ambientSessionID == nil {
            ambientSessionID = outcome.session.id
            log.info("Bookmark minted ambient session id=\(outcome.session.id) (tracker adopted)")
        }
        return outcome
    }

    /// Close every live-tracked session. Called on app shutdown so the
    /// timeline shows tidy ended_at values for the most recent run.
    func closeAll(at when: Date = Date()) async {
        await micStopped(at: when)
        await systemStopped(at: when)
    }
}
