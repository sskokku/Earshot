//
//  LiveTranscript.swift
//  EarShot
//

import Foundation
import Observation

/// In-memory feed the floating panel binds to. Finalized segments are appended,
/// the provisional string is overwritten while a speaker is mid-utterance.
///
/// CLAUDE.md rule 2: nothing accumulates without bound — the live panel keeps a
/// fixed-size ring of the most recent segments. The on-disk transcript writer
/// (lands in chunk 4) is the long-term store.
@MainActor
@Observable
final class LiveTranscript {
    struct Segment: Identifiable, Equatable {
        let id: UUID
        let startedAt: Date
        let endedAt: Date
        let source: Source
        /// Diarization label for this segment, e.g. "Speaker 1". Session-local
        /// for Phase 2 chunk S1. May be `nil` if the diarizer had not yet
        /// observed overlapping speech (rare; happens at the very first
        /// utterance before the model warms up).
        let speakerLabel: String?
        let text: String
        /// CLAUDE.md segments-schema: `provisional INTEGER NOT NULL DEFAULT 1`.
        /// Rule 3 — every segment minted by the live path is provisional; the
        /// Phase 4 offline correction pass is the only writer allowed to flip
        /// this to `false`. Defaulted to `true` so the live constructors stay
        /// unchanged; SQLite persistence lands in S2.
        let provisional: Bool
        /// S4 — persistent speaker primary key once the resolver has run.
        /// Carried on the segment so the inline naming UI in the panel can
        /// open a rename sheet on a row without a label-string round-trip
        /// to the library. `nil` for the pre-resolution path (no resolver,
        /// no slot label, owner zero-id sentinel).
        let speakerID: Int64?

        enum Source: String, Equatable {
            case mic
            case system
        }

        nonisolated init(
            id: UUID,
            startedAt: Date,
            endedAt: Date,
            source: Source,
            speakerLabel: String?,
            text: String,
            provisional: Bool = true,
            speakerID: Int64? = nil
        ) {
            self.id = id
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.source = source
            self.speakerLabel = speakerLabel
            self.text = text
            self.provisional = provisional
            self.speakerID = speakerID
        }
    }

    /// Most recent finalized segments, oldest first. Capped at `maxSegments`.
    private(set) var segments: [Segment] = []

    /// Text being spoken right now. Empty between utterances.
    var provisional: String = ""

    /// Cap for in-memory display. The disk transcript is the source of truth.
    let maxSegments: Int = 200

    func appendFinalized(_ segment: Segment) {
        segments.append(segment)
        if segments.count > maxSegments {
            segments.removeFirst(segments.count - maxSegments)
        }
        provisional = ""
    }

    func updateProvisional(_ text: String) {
        provisional = text
    }

    func clearProvisional() {
        provisional = ""
    }

    /// CP1 — apply silent relabel updates from the offline correction
    /// pass (PRD R6, CLAUDE.md rule 3). One pass can touch several
    /// segments; we scan once and replace each match in place so
    /// SwiftUI sees a single observable change. Match is on
    /// (source, startedAt, text) so two speakers with the same instant
    /// can't relabel each other.
    func applyCorrectionUpdates(_ updates: [CorrectionLiveUpdate]) {
        guard !updates.isEmpty, !segments.isEmpty else { return }
        // Index updates by their match key so we can do a single O(n)
        // scan over `segments` rather than n·m.
        struct Key: Hashable { let source: Segment.Source; let started: Date; let text: String }
        var lookup: [Key: CorrectionLiveUpdate] = [:]
        for u in updates {
            lookup[Key(source: u.source, started: u.startedAt, text: u.text)] = u
        }
        var didChange = false
        for i in 0..<segments.count {
            let s = segments[i]
            let key = Key(source: s.source, started: s.startedAt, text: s.text)
            guard let update = lookup[key] else { continue }
            // Skip if nothing actually changed (idempotent re-apply).
            if s.speakerLabel == update.newSpeakerLabel,
               s.speakerID == update.newSpeakerID,
               s.provisional == false {
                continue
            }
            segments[i] = Segment(
                id: s.id,
                startedAt: s.startedAt,
                endedAt: s.endedAt,
                source: s.source,
                speakerLabel: update.newSpeakerLabel,
                text: s.text,
                provisional: false,
                speakerID: update.newSpeakerID
            )
            didChange = true
        }
        // Reassigning the array isn't necessary — Observation tracks the
        // mutating subscript. `didChange` is kept so future logging can
        // distinguish silent no-ops from real updates.
        _ = didChange
    }
}

/// CP1 — carrier for one panel-side relabel emitted by the offline
/// correction pass. Sendable so the AppDelegate hop into MainActor with
/// the batch is safe under Swift 6 strictness.
struct CorrectionLiveUpdate: Sendable, Equatable {
    let source: LiveTranscript.Segment.Source
    let startedAt: Date
    let text: String
    let newSpeakerLabel: String
    let newSpeakerID: Int64?
}
