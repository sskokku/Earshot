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

    /// In-memory representation of a user-dropped bookmark. The id is
    /// the SQLite row id from `SpeakerLibrary.Bookmark.id` so the panel
    /// can de-duplicate if the same bookmark is appended twice (defensive
    /// — the current call site only appends once per drop).
    struct BookmarkEntry: Identifiable, Equatable {
        let id: Int64
        let capturedAt: Date
        let label: String
    }

    /// One row in the merged display order. The panel iterates this so
    /// segments and bookmarks render in chronological order without the
    /// view layer juggling two arrays. Stable across rebuilds because
    /// `id` carries the underlying row identity.
    enum DisplayEntry: Identifiable, Equatable {
        case segment(Segment)
        case bookmark(BookmarkEntry)

        var id: String {
            switch self {
            case .segment(let s): return "seg-\(s.id.uuidString)"
            case .bookmark(let b): return "bm-\(b.id)"
            }
        }

        var timestamp: Date {
            switch self {
            case .segment(let s): return s.startedAt
            case .bookmark(let b): return b.capturedAt
            }
        }
    }

    /// Most recent finalized segments, oldest first. Capped at `maxSegments`.
    private(set) var segments: [Segment] = []

    /// User bookmarks dropped during the current panel lifetime. The
    /// reader window backfills historical bookmarks from the .md file
    /// directly; this array is panel-session-scoped, matching the
    /// segments behavior.
    private(set) var bookmarks: [BookmarkEntry] = []

    /// Text being spoken right now. Empty between utterances.
    var provisional: String = ""

    /// Cap for in-memory display. The disk transcript is the source of truth.
    let maxSegments: Int = 200

    /// Cap for in-memory bookmark display. A handful per session is
    /// typical; the cap defends against a hotkey held down accidentally.
    let maxBookmarks: Int = 50

    /// Merged chronological view used by the panel. Segments win ties on
    /// equal timestamps so a bookmark dropped on the same instant as a
    /// segment renders just after the line it labels — which reads more
    /// naturally ("she said X — bookmark: 'key decision'").
    var displayEntries: [DisplayEntry] {
        var merged: [DisplayEntry] = []
        merged.reserveCapacity(segments.count + bookmarks.count)
        for s in segments { merged.append(.segment(s)) }
        for b in bookmarks { merged.append(.bookmark(b)) }
        merged.sort { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                switch (lhs, rhs) {
                case (.segment, .bookmark): return true
                case (.bookmark, .segment): return false
                default: return false
                }
            }
            return lhs.timestamp < rhs.timestamp
        }
        return merged
    }

    func appendFinalized(_ segment: Segment) {
        segments.append(segment)
        if segments.count > maxSegments {
            segments.removeFirst(segments.count - maxSegments)
        }
        provisional = ""
    }

    /// Append a freshly-dropped bookmark to the live display. Idempotent
    /// on `id` so a duplicate call (e.g. retried delivery) doesn't double
    /// the divider. Replaces an earlier entry if the bookmark was renamed
    /// (not currently supported, but cheap to handle).
    func appendBookmark(_ bookmark: BookmarkEntry) {
        if let idx = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[idx] = bookmark
        } else {
            bookmarks.append(bookmark)
        }
        if bookmarks.count > maxBookmarks {
            bookmarks.removeFirst(bookmarks.count - maxBookmarks)
        }
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
