//
//  SpeakerLibrary.swift
//  EarShot
//

import Foundation
import GRDB
import os

/// Persistent speaker library backed by SQLite (GRDB).
///
/// Schema lives in CLAUDE.md §"Speaker library schema" plus the v2 migration
/// here that adds `display_label`. Three tables:
///
/// - `speakers`: one row per persistent identity. `name` is NULL until the
///   user assigns one. `display_label` is what the live panel + transcript
///   render when `name` is NULL (e.g., "Speaker 3"). `merged_into` (S4) lets
///   two entries collapse without losing history.
/// - `embeddings`: 256-d Float32 WeSpeaker vectors stored as BLOBs. Tagged
///   with the context (`mic` / `system`) the embedding was captured in so
///   matching can apply same-context vs cross-context thresholds (S3).
///   Capped at 10 per speaker per context — overflow replaces the
///   lowest-quality row.
/// - `segments`: schema present so the correction pass (Phase 4) and FTS5
///   keyword search (S4) can write here without another migration. S3 does
///   not yet populate this table; the live path still owns the on-disk
///   Markdown writer and the segment index will be backfilled when the
///   correction pass lands.
///
/// S3 added: query and mutation surface for the IdentityResolver. The S2
/// session-scoped slot map (`sessionMap`, `ensureSpeaker`) is gone — once
/// identity matching is in place, that path would duplicate persistent
/// speakers on every pipeline restart. IdentityResolver replaces it with
/// embedding-based matching against the live library state, so a quiet day
/// no longer mints N rows for the same physical person on every reboot.
///
/// S4 added: live-path segment indexing (the live merge layer now writes a
/// row per finalized segment so FTS5 search is fed continuously), the v3
/// migration that stands up an external-content `segments_fts` virtual table
/// with the porter tokenizer plus a `search_log` table for PRD R8's
/// "searches run" counter, and the transactional naming / merge / clear /
/// delete / re-enroll surface used by `SpeakerLibraryWindow`. Naming and
/// merging both rewrite today's Markdown atomically inside the same DB
/// transaction (FileManager.replaceItemAt under dbQueue.write — if the file
/// swap throws the SQL update rolls back), so CLAUDE.md's "transactional
/// speaker naming" rule is enforced at the data layer rather than left to
/// AppDelegate coordination.
actor SpeakerLibrary {
    enum Context: String, Sendable {
        case mic
        case system
    }

    /// One row from the `embeddings` table, hydrated into a Swift-side
    /// vector. Returned by `allEmbeddings(context:)` for IdentityResolver to
    /// cosine-compare.
    struct SpeakerEmbedding: Sendable {
        let speakerID: Int64
        let vector: [Float]
        let quality: Double
    }

    /// Returned by `dumpCounts()` for the debug menu item.
    struct Counts: Sendable {
        let speakerCount: Int
        let embeddingCount: Int
        let micEmbeddingCount: Int
        let systemEmbeddingCount: Int
        let ownerName: String?
        let ownerSpeakerID: Int64?
        let ownerEmbeddingCount: Int
        /// Per-speaker breakdown for the debug dump. Trimmed to top 10 by
        /// embedding count so the alert stays readable.
        let perSpeaker: [SpeakerSummary]
    }

    struct SpeakerSummary: Sendable {
        let id: Int64
        /// Display label (name if assigned, otherwise the persistent
        /// "Speaker N" minted at row creation).
        let label: String
        let micCount: Int
        let systemCount: Int
    }

    /// Per-pipeline-boot token. `MicPipeline.start` / `SystemAudioPipeline.start`
    /// mints one of these and uses its `id` as the session-scope key for the
    /// IdentityResolver cache. The library itself no longer holds session
    /// state — S2's in-memory slot map was redundant once identity matching
    /// landed in S3.
    struct SessionToken: Sendable, Hashable {
        let id: UUID
    }

    // MARK: - Resolver telemetry (match decisions)

    /// One resolver outcome class per decision-row. Mirrors the os_log
    /// tags the resolver already emits, minus CACHE-HIT (echoes a prior
    /// decision, carries no candidate-set scores, so it would just be
    /// nulls on every analytic column).
    enum MatchDecisionOutcome: String, Sendable {
        case matchSame = "match-same"
        case matchCross = "match-cross"
        case noMatch = "no-match"
        case noEmbedding = "no-embedding"
    }

    /// Carrier the IdentityResolver hands to `recordMatchDecision`. One
    /// row per resolve call captures everything the user would later need
    /// to ask "why did this voice mint a new speaker instead of matching?"
    /// — the per-context best candidate + score + the thresholds in force
    /// at decision time (so a future threshold change does not retroactively
    /// invalidate the historical record).
    struct MatchDecisionRecord: Sendable {
        let decidedAt: Date
        let context: Context
        let sessionID: UUID
        let slotLabel: String
        let outcome: MatchDecisionOutcome
        /// The speaker the resolver returned: an existing speaker on
        /// MATCH-SAME/CROSS, the freshly-minted speaker on NO-MATCH, the
        /// minted-or-fallback on NO-EMBEDDING. Nil only if the mint
        /// itself failed.
        let resolvedSpeakerID: Int64?
        let bestSameSpeakerID: Int64?
        let bestSameScore: Double?
        let bestCrossSpeakerID: Int64?
        let bestCrossScore: Double?
        let sameThreshold: Double
        let crossThreshold: Double
        let sameCandidateCount: Int
        let crossCandidateCount: Int
    }

    /// One labeled NO-MATCH row used by the threshold-sweep math. Pulled
    /// from `match_decisions` after `ground_truth_speaker_id` has been
    /// backfilled by a user merge. The two scores (best-same vs the
    /// ground-truth speaker, best-cross vs ground-truth) are nil when the
    /// correct speaker was not the top candidate in that context — useful
    /// to distinguish "threshold too strict" (score is high but below
    /// gate) from "embedding noise" (correct speaker wasn't even closest).
    struct LabeledMissRow: Sendable {
        let context: Context
        let groundTruthSpeakerID: Int64
        let sameScore: Double?      // best_same_score, only if best_same_speaker_id == ground_truth
        let crossScore: Double?     // best_cross_score, only if best_cross_speaker_id == ground_truth
        let sameThreshold: Double
        let crossThreshold: Double
        /// True if the best candidate IN EITHER CONTEXT was a NAMED speaker
        /// different from ground truth — proxy for "lowering the threshold
        /// here would have caused a false merge into a named person."
        let bestSameWasNamedNonMatch: Bool
        let bestCrossWasNamedNonMatch: Bool
    }

    /// Retroactive analysis surface: for every speaker that the user has
    /// already merged into another (`speakers.merged_into IS NOT NULL`),
    /// the maximum cosine similarity between source and destination
    /// embeddings AS THEY EXIST NOW. This is an upper-bound proxy for the
    /// near-miss score the live resolver would have seen at the original
    /// split moment — embeddings drift but the per-context cap (10) keeps
    /// drift bounded.
    struct HistoricalMergeScore: Sendable, Identifiable {
        var id: Int64 { sourceSpeakerID }
        let sourceSpeakerID: Int64
        let destinationSpeakerID: Int64
        let destinationLabel: String
        /// max(maxCosine(source.mic, destination.mic),
        ///     maxCosine(source.system, destination.system)).
        /// Nil if either side has no embeddings in any same-context bag.
        let maxSameContextScore: Double?
        /// max(maxCosine(source.mic, destination.system),
        ///     maxCosine(source.system, destination.mic)).
        let maxCrossContextScore: Double?
    }

    /// Aggregate the curation window renders. Combines live decision
    /// telemetry (sharp scores at decision time, only available going
    /// forward) and retroactive merge analysis (works on existing data).
    struct MatchDecisionStats: Sendable {

        struct HistogramBin: Sendable, Identifiable {
            /// Bin lower bound, encoded as id so SwiftUI ForEach keys stably.
            var id: Double { lowerBound }
            let lowerBound: Double
            let upperBound: Double
            let count: Int
        }

        struct ThresholdSweepRow: Sendable, Identifiable {
            var id: Double { threshold }
            let threshold: Double
            /// Labeled misses where best-same speaker == ground truth AND
            /// best-same score ≥ threshold. "Lowering the gate to T would
            /// have caught this many past splits in same-context."
            let sameContextTruePositives: Int
            /// Labeled misses where best-same speaker != ground truth AND
            /// best-same speaker is NAMED AND best-same score ≥ threshold.
            /// "Lowering the gate to T would have caused this many wrong
            /// merges into a named person."
            let sameContextFalsePositives: Int
            let crossContextTruePositives: Int
            let crossContextFalsePositives: Int
        }

        struct PerSpeakerMissRow: Sendable, Identifiable {
            var id: Int64 { speakerID }
            let speakerID: Int64
            let label: String
            let missCount: Int
            let medianNearMissScore: Double?
        }

        let currentSameThreshold: Double
        let currentCrossThreshold: Double

        let liveDecisionTotal: Int
        let liveNoMatchTotal: Int
        let liveLabeledMissTotal: Int

        let historicalMergePairCount: Int

        let sameContextHistogram: [HistogramBin]
        let crossContextHistogram: [HistogramBin]

        let medianSameContextNearMiss: Double?
        let medianCrossContextNearMiss: Double?

        let micMissCount: Int
        let systemMissCount: Int

        let topMissedSpeakers: [PerSpeakerMissRow]

        let thresholdSweep: [ThresholdSweepRow]
    }

    private let log = Logger(subsystem: "com.earshot.app", category: "SpeakerLibrary")
    private let dbQueue: DatabaseQueue

    /// Cap per CLAUDE.md "Matching policy" §: "Keep at most 10 embeddings
    /// per speaker per context; replace lowest-quality on overflow."
    private let maxEmbeddingsPerContext = 10

    /// Per-segment quality scales with utterance duration up to a cap. A 10s
    /// utterance scores 1.0, a 0.5s blip scores 0.05. This is the proxy
    /// CLAUDE.md calls out ("duration/SNR-derived confidence"); a future
    /// pass folds in SNR once matching makes a stronger quality signal
    /// worth the extra compute.
    private static let qualityReferenceSeconds: Double = 10.0

    // MARK: - Init

    /// Opens (or creates) the library DB at the canonical path and runs
    /// migrations. Throws if the file cannot be created or migrated.
    init() throws {
        let url = try AppSettings.speakerLibraryURL()
        let config = SpeakerLibrary.makeConfiguration()
        self.dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try SpeakerLibrary.migrator.migrate(self.dbQueue)
    }

    /// Test-only entry: open against an in-memory queue so unit tests can
    /// exercise the cap-and-replace and matching surface without touching
    /// Application Support.
    init(testQueue: DatabaseQueue) throws {
        self.dbQueue = testQueue
        try SpeakerLibrary.migrator.migrate(self.dbQueue)
    }

    private static func makeConfiguration(_ config: Configuration = Configuration()) -> Configuration {
        var c = config
        c.foreignKeysEnabled = true
        return c
    }

    /// Schema migrator. v1 creates the three tables verbatim from
    /// CLAUDE.md §"Speaker library schema". v2 adds `display_label` so an
    /// unnamed speaker carries a stable "Speaker N" string across
    /// sessions (its persistent identity until the user names it in S4).
    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_speakers_embeddings_segments") { db in
            try db.execute(sql: """
                CREATE TABLE speakers (
                    id INTEGER PRIMARY KEY,
                    name TEXT,
                    created_at TEXT NOT NULL,
                    merged_into INTEGER REFERENCES speakers(id)
                )
                """)

            try db.execute(sql: """
                CREATE TABLE embeddings (
                    id INTEGER PRIMARY KEY,
                    speaker_id INTEGER NOT NULL REFERENCES speakers(id),
                    context TEXT NOT NULL CHECK (context IN ('mic','system')),
                    vector BLOB NOT NULL,
                    quality REAL,
                    created_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_embeddings_speaker_context
                ON embeddings(speaker_id, context)
                """)

            try db.execute(sql: """
                CREATE TABLE segments (
                    id INTEGER PRIMARY KEY,
                    date TEXT NOT NULL,
                    start_ts REAL NOT NULL,
                    end_ts REAL NOT NULL,
                    source TEXT NOT NULL CHECK (source IN ('mic','system')),
                    session_id TEXT NOT NULL,
                    speaker_id INTEGER REFERENCES speakers(id),
                    provisional INTEGER NOT NULL DEFAULT 1,
                    text TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_segments_date ON segments(date)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_segments_speaker ON segments(speaker_id)
                """)
        }

        migrator.registerMigration("v2_speaker_display_label") { db in
            try db.execute(sql: "ALTER TABLE speakers ADD COLUMN display_label TEXT")

            // Backfill named rows (owner) with their name.
            try db.execute(sql: """
                UPDATE speakers SET display_label = name
                WHERE name IS NOT NULL AND display_label IS NULL
                """)

            // Backfill unnamed rows with sequential "Speaker N" labels in
            // id order. This is the only place we ever look at row ordering
            // to assign labels — new mints after this migration use the
            // `nextUnnamedDisplayLabel` helper, which scans existing labels.
            let unnamedIDs = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM speakers WHERE name IS NULL AND display_label IS NULL ORDER BY id"
            )
            for (offset, id) in unnamedIDs.enumerated() {
                let label = "Speaker \(offset + 1)"
                try db.execute(
                    sql: "UPDATE speakers SET display_label = ? WHERE id = ?",
                    arguments: [label, id]
                )
            }
        }

        // S4 — FTS5 keyword search over segments + search log.
        // `segments_fts` is an external-content table synchronized with
        // `segments` so we don't store the text twice. GRDB installs the
        // INSERT/UPDATE/DELETE triggers itself; existing rows are
        // backfilled by the migration. Porter wrapping unicode61 gives
        // English stemming + diacritics-insensitive matching, which is the
        // closest fit for casual speech transcription.
        migrator.registerMigration("v3_segments_fts_and_search_log") { db in
            try db.create(virtualTable: "segments_fts", using: FTS5()) { t in
                t.synchronize(withTable: "segments")
                t.tokenizer = .porter()
                t.column("text")
            }

            try db.execute(sql: """
                CREATE TABLE search_log (
                    id INTEGER PRIMARY KEY,
                    query TEXT NOT NULL,
                    result_count INTEGER NOT NULL,
                    executed_at TEXT NOT NULL
                )
                """)
        }

        // Sessions + bookmarks. A session is a bounded stretch with
        // start, end (NULL while open), type (call/ambient), source
        // (mic/system/both), and an optional user label. The next chunk
        // renders these on a timeline; this chunk owns the data model
        // and the live tracker.
        //
        // Backfill at migration time: every existing (source, session_id)
        // group in the segments table is one historical session row.
        // type = 'call' for system, else 'ambient'. started_at = MIN,
        // ended_at = MAX. No label (the timeline UI in the next chunk
        // will let the user retroactively attach one).
        migrator.registerMigration("v4_sessions_and_bookmarks") { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                    id INTEGER PRIMARY KEY,
                    type TEXT NOT NULL CHECK (type IN ('call','ambient')),
                    source TEXT NOT NULL CHECK (source IN ('mic','system','both')),
                    label TEXT,
                    started_at REAL NOT NULL,
                    ended_at REAL,
                    created_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_sessions_started_at ON sessions(started_at)")
            try db.execute(sql: "CREATE INDEX idx_sessions_ended_at ON sessions(ended_at)")

            try db.execute(sql: """
                CREATE TABLE bookmarks (
                    id INTEGER PRIMARY KEY,
                    session_id INTEGER REFERENCES sessions(id),
                    label TEXT NOT NULL,
                    captured_at REAL NOT NULL,
                    created_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_bookmarks_captured_at ON bookmarks(captured_at)")
            try db.execute(sql: "CREATE INDEX idx_bookmarks_session_id ON bookmarks(session_id)")

            try db.execute(
                sql: """
                    INSERT INTO sessions (type, source, started_at, ended_at, created_at)
                    SELECT
                        CASE WHEN source = 'system' THEN 'call' ELSE 'ambient' END,
                        source,
                        MIN(start_ts),
                        MAX(end_ts),
                        ?
                    FROM segments
                    WHERE session_id IS NOT NULL AND session_id <> ''
                    GROUP BY source, session_id
                    """,
                arguments: [SpeakerLibrary.timestampString()]
            )
        }

        // Resolver telemetry. One row per IdentityResolver decision
        // (except CACHE-HIT, which echoes an earlier decision and has no
        // candidate scores). Captures the per-context best candidate +
        // score + thresholds-in-force so a future threshold change does
        // not retroactively invalidate the historical record. The
        // `ground_truth_speaker_id` column is null until the user later
        // merges the row's resolved speaker — `mergeSpeakers` backfills
        // it inside the same transaction as the merge itself, which is
        // how "the correct answer was Y all along" propagates onto
        // every prior misclassification.
        //
        // Volume: ~one row per finalized utterance with an embedding.
        // A heavy day (~1000 segments) is ~150 KB on disk; a year is
        // ~50 MB. Small enough that no retention policy lives here
        // today; if it becomes a problem a 90-day rolling delete is a
        // one-liner.
        migrator.registerMigration("v5_match_decisions") { db in
            try db.execute(sql: """
                CREATE TABLE match_decisions (
                    id INTEGER PRIMARY KEY,
                    decided_at TEXT NOT NULL,
                    source TEXT NOT NULL CHECK (source IN ('mic','system')),
                    session_id TEXT NOT NULL,
                    slot_label TEXT NOT NULL,
                    outcome TEXT NOT NULL CHECK (outcome IN ('match-same','match-cross','no-match','no-embedding')),
                    resolved_speaker_id INTEGER REFERENCES speakers(id),
                    best_same_speaker_id INTEGER REFERENCES speakers(id),
                    best_same_score REAL,
                    best_cross_speaker_id INTEGER REFERENCES speakers(id),
                    best_cross_score REAL,
                    same_threshold REAL NOT NULL,
                    cross_threshold REAL NOT NULL,
                    same_candidate_count INTEGER NOT NULL,
                    cross_candidate_count INTEGER NOT NULL,
                    ground_truth_speaker_id INTEGER REFERENCES speakers(id)
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_match_decisions_decided_at ON match_decisions(decided_at)")
            try db.execute(sql: "CREATE INDEX idx_match_decisions_resolved ON match_decisions(resolved_speaker_id)")
            try db.execute(sql: "CREATE INDEX idx_match_decisions_ground_truth ON match_decisions(ground_truth_speaker_id)")

            // Snapshot scores at the moment of merge. `mergeSpeakers`
            // reassigns the source's embeddings to the destination, so a
            // cosine sweep after the fact returns nothing useful. The
            // audit row captures max same- and cross-context cosines
            // between source and destination IMMEDIATELY BEFORE the
            // reassignment, which is the only correct moment to read
            // the source's evidence.
            try db.execute(sql: """
                CREATE TABLE merge_audit (
                    id INTEGER PRIMARY KEY,
                    source_speaker_id INTEGER NOT NULL,
                    destination_speaker_id INTEGER NOT NULL,
                    merged_at TEXT NOT NULL,
                    max_same_context_score REAL,
                    max_cross_context_score REAL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_merge_audit_destination ON merge_audit(destination_speaker_id)")
        }
        return migrator
    }

    // MARK: - Owner enrollment

    /// Inserts (or updates) the owner's persistent speaker row and seeds it
    /// with the enrollment embedding. Idempotent: re-running with a fresh
    /// embedding adds a new row up to the cap and replaces the
    /// lowest-quality one on overflow.
    ///
    /// Returns the owner's persistent speaker id, which is also persisted
    /// to `AppSettings.ownerSpeakerIDValue` so other components can look up
    /// the owner without a name lookup.
    @discardableResult
    func enrollOwner(name: String, embedding: [Float]) throws -> Int64 {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? "Me" : trimmedName
        let nowText = SpeakerLibrary.timestampString()

        let speakerID: Int64 = try dbQueue.write { db in
            if let existing = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM speakers WHERE id = ? LIMIT 1",
                arguments: [AppSettings.ownerSpeakerIDValue ?? -1]
            ) {
                // Refresh the name if the user re-ran onboarding with a new
                // name; merge state is left alone. display_label tracks the
                // name for named rows so the panel renders consistently.
                try db.execute(
                    sql: "UPDATE speakers SET name = ?, display_label = ? WHERE id = ?",
                    arguments: [displayName, displayName, existing]
                )
                return existing
            }
            try db.execute(
                sql: """
                    INSERT INTO speakers (name, created_at, merged_into, display_label)
                    VALUES (?, ?, NULL, ?)
                    """,
                arguments: [displayName, nowText, displayName]
            )
            return db.lastInsertedRowID
        }

        AppSettings.ownerName = displayName
        AppSettings.ownerSpeakerIDValue = speakerID

        // Enrollment embedding gets the maximum quality score — the user
        // sat through a 30 s controlled capture, so it is by definition the
        // best sample we will ever have of this voice.
        try recordEmbedding(
            speakerID: speakerID,
            context: .mic,
            vector: embedding,
            quality: 1.0
        )
        return speakerID
    }

    /// One-shot migration from Chunk 2's me_embedding.bin into the GRDB
    /// library. Called from `init` paths that have an `AppSettings.ownerName`
    /// from a prior install but no owner speaker row yet.
    ///
    /// Returns the new owner id if migration happened, nil if nothing was
    /// migrated (no .bin on disk, or owner already in DB).
    @discardableResult
    func migrateOwnerEmbeddingFileIfNeeded() throws -> Int64? {
        // Bail if owner already exists in DB.
        if let existingID = AppSettings.ownerSpeakerIDValue {
            let exists: Bool = try dbQueue.read { db in
                try Bool.fetchOne(
                    db,
                    sql: "SELECT 1 FROM speakers WHERE id = ? LIMIT 1",
                    arguments: [existingID]
                ) ?? false
            }
            if exists { return nil }
        }

        let url: URL
        do {
            url = try AppSettings.ownerEmbeddingURL()
        } catch {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            log.error("Owner-embedding file present but unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0, data.count == count * MemoryLayout<Float>.size else {
            log.error("Owner-embedding file has invalid length (\(data.count) bytes)")
            return nil
        }
        let vector: [Float] = data.withUnsafeBytes { raw -> [Float] in
            let floats = raw.bindMemory(to: Float.self)
            return Array(floats.prefix(count))
        }

        let name = AppSettings.ownerName ?? "Me"
        let speakerID = try enrollOwner(name: name, embedding: vector)
        log.info("Migrated owner embedding from me_embedding.bin into speakers id=\(speakerID)")
        return speakerID
    }

    // MARK: - Session tokens

    /// Mint a fresh session token. Each pipeline's `start()` calls this so
    /// the IdentityResolver's per-(source, session, slot) cache starts
    /// clean across restarts.
    func newSession() -> SessionToken {
        SessionToken(id: UUID())
    }

    // MARK: - S3 matching surface

    /// Return every embedding for the given context, decoded into Swift
    /// vectors. IdentityResolver calls this once per finalized segment when
    /// the cache misses. The library cap (10 per speaker per context) keeps
    /// the result set bounded — at full saturation with N speakers, this
    /// returns at most 10·N rows per context.
    func allEmbeddings(context: Context) throws -> [SpeakerEmbedding] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT speaker_id, vector, quality
                    FROM embeddings
                    WHERE context = ?
                    """,
                arguments: [context.rawValue]
            )
            return rows.compactMap { row -> SpeakerEmbedding? in
                guard let blob: Data = row["vector"] else { return nil }
                let speakerID: Int64 = row["speaker_id"]
                let quality: Double = row["quality"] ?? 0
                let count = blob.count / MemoryLayout<Float>.size
                guard count > 0 else { return nil }
                let vector: [Float] = blob.withUnsafeBytes { raw in
                    let floats = raw.bindMemory(to: Float.self)
                    return Array(floats.prefix(count))
                }
                return SpeakerEmbedding(speakerID: speakerID, vector: vector, quality: quality)
            }
        }
    }

    /// Display label for a speaker row: the user-assigned `name` if set,
    /// otherwise the persistent "Speaker N" minted at row creation. Returns
    /// nil if the row was deleted (shouldn't happen — segments + embeddings
    /// reference speakers via FK).
    func displayLabel(forSpeakerID id: Int64) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(name, display_label)
                    FROM speakers WHERE id = ?
                    """,
                arguments: [id]
            )
        }
    }

    /// Mint a new unnamed speaker row with a stable "Speaker N" display
    /// label. N is the next unused integer among existing "Speaker N"
    /// labels, so named speakers (S4) no longer shift the unnamed
    /// sequence. Returns `(speakerID, displayLabel)`.
    func createUnnamedSpeaker() throws -> (speakerID: Int64, displayLabel: String) {
        let nowText = SpeakerLibrary.timestampString()
        return try dbQueue.write { db in
            let label = try Self.nextUnnamedDisplayLabel(db: db)
            try db.execute(
                sql: """
                    INSERT INTO speakers (name, created_at, merged_into, display_label)
                    VALUES (NULL, ?, NULL, ?)
                    """,
                arguments: [nowText, label]
            )
            return (db.lastInsertedRowID, label)
        }
    }

    /// Scan existing `display_label` values for the highest "Speaker N"
    /// suffix; return "Speaker N+1". Owner rows (display_label = name) are
    /// invisible to this scan because their labels don't match the
    /// "Speaker N" pattern.
    private static func nextUnnamedDisplayLabel(db: Database) throws -> String {
        let labels = try String.fetchAll(
            db,
            sql: "SELECT display_label FROM speakers WHERE display_label IS NOT NULL"
        )
        var maxN = 0
        for label in labels {
            guard label.hasPrefix("Speaker ") else { continue }
            let suffix = label.dropFirst("Speaker ".count)
            if let n = Int(suffix), n > maxN {
                maxN = n
            }
        }
        return "Speaker \(maxN + 1)"
    }

    // MARK: - Embedding storage

    /// Records an embedding for a speaker. Enforces the per-context cap by
    /// replacing the lowest-quality existing row when the speaker already
    /// has 10 embeddings in the same context.
    ///
    /// Quality is a 0…1 score (higher is better). `qualityFromDuration` is
    /// the helper to use from the resolver — it bakes in the
    /// `qualityReferenceSeconds` curve.
    func recordEmbedding(
        speakerID: Int64,
        context: Context,
        vector: [Float],
        quality: Double
    ) throws {
        guard !vector.isEmpty else { return }
        let blob = vector.withUnsafeBufferPointer { buffer -> Data in
            Data(buffer: buffer)
        }
        let nowText = SpeakerLibrary.timestampString()
        let clampedQuality = max(0.0, min(1.0, quality))
        let cap = maxEmbeddingsPerContext

        try dbQueue.write { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM embeddings WHERE speaker_id = ? AND context = ?",
                arguments: [speakerID, context.rawValue]
            ) ?? 0

            if count < cap {
                try db.execute(
                    sql: """
                    INSERT INTO embeddings (speaker_id, context, vector, quality, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [speakerID, context.rawValue, blob, clampedQuality, nowText]
                )
                return
            }

            // Cap hit. Find the existing row with the lowest quality and
            // replace it. Ties broken by older `created_at` so we always
            // displace the staler sample. If the incoming embedding is
            // strictly worse than the current minimum, we drop it instead
            // of taking up an INSERT — keeping the best 10 samples is the
            // point of the cap.
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, quality FROM embeddings
                WHERE speaker_id = ? AND context = ?
                ORDER BY COALESCE(quality, 0) ASC, created_at ASC
                LIMIT 1
                """,
                arguments: [speakerID, context.rawValue]
            )
            guard let row else { return }
            let existingID: Int64 = row["id"]
            let existingQuality: Double? = row["quality"]
            let existingScore = existingQuality ?? 0.0
            if clampedQuality < existingScore { return }
            try db.execute(
                sql: """
                UPDATE embeddings
                SET vector = ?, quality = ?, created_at = ?
                WHERE id = ?
                """,
                arguments: [blob, clampedQuality, nowText, existingID]
            )
        }
    }

    /// Convenience: turn an utterance duration into the 0…1 quality score
    /// used by `recordEmbedding`.
    static func qualityFromDuration(seconds: Double) -> Double {
        let raw = seconds / qualityReferenceSeconds
        return max(0.0, min(1.0, raw))
    }

    // MARK: - Debug dump

    func dumpCounts() throws -> Counts {
        try dbQueue.read { db in
            let speakerCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speakers") ?? 0
            let micCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM embeddings WHERE context = 'mic'"
            ) ?? 0
            let sysCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM embeddings WHERE context = 'system'"
            ) ?? 0

            let ownerID = AppSettings.ownerSpeakerIDValue
            var ownerName: String?
            var ownerEmbeddingCount = 0
            if let ownerID {
                ownerName = try String.fetchOne(
                    db,
                    sql: "SELECT name FROM speakers WHERE id = ?",
                    arguments: [ownerID]
                )
                ownerEmbeddingCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM embeddings WHERE speaker_id = ?",
                    arguments: [ownerID]
                ) ?? 0
            }

            // Top 10 by embedding count. Owner is included naturally.
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id AS id,
                       COALESCE(s.name, s.display_label, 'Speaker ?') AS label,
                       COALESCE(SUM(CASE WHEN e.context = 'mic' THEN 1 ELSE 0 END), 0) AS mic_count,
                       COALESCE(SUM(CASE WHEN e.context = 'system' THEN 1 ELSE 0 END), 0) AS system_count
                FROM speakers s
                LEFT JOIN embeddings e ON e.speaker_id = s.id
                GROUP BY s.id
                ORDER BY (mic_count + system_count) DESC, s.id ASC
                LIMIT 10
                """)
            let perSpeaker: [SpeakerSummary] = rows.map { row in
                SpeakerSummary(
                    id: row["id"],
                    label: row["label"] ?? "Speaker ?",
                    micCount: row["mic_count"] ?? 0,
                    systemCount: row["system_count"] ?? 0
                )
            }

            return Counts(
                speakerCount: speakerCount,
                embeddingCount: micCount + sysCount,
                micEmbeddingCount: micCount,
                systemEmbeddingCount: sysCount,
                ownerName: ownerName,
                ownerSpeakerID: ownerID,
                ownerEmbeddingCount: ownerEmbeddingCount,
                perSpeaker: perSpeaker
            )
        }
    }

    // MARK: - S4 listing surface

    /// One row for the `SpeakerLibraryWindow` list. Mirrors `SpeakerSummary`
    /// but isn't capped at 10 — the window may show dozens.
    struct SpeakerRow: Sendable, Identifiable, Equatable {
        let id: Int64
        let name: String?
        let displayLabel: String
        let micCount: Int
        let systemCount: Int
        let mergedInto: Int64?
        let isOwner: Bool
    }

    /// Every speaker in the library with their per-context embedding counts.
    /// Used by `SpeakerLibraryWindow`. Sorted: owner first, then named,
    /// then unnamed-by-id.
    func listSpeakers() throws -> [SpeakerRow] {
        let ownerID = AppSettings.ownerSpeakerIDValue
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id AS id,
                       s.name AS name,
                       COALESCE(s.display_label, 'Speaker ?') AS label,
                       s.merged_into AS merged_into,
                       COALESCE(SUM(CASE WHEN e.context = 'mic' THEN 1 ELSE 0 END), 0) AS mic_count,
                       COALESCE(SUM(CASE WHEN e.context = 'system' THEN 1 ELSE 0 END), 0) AS system_count
                FROM speakers s
                LEFT JOIN embeddings e ON e.speaker_id = s.id
                GROUP BY s.id
                ORDER BY s.id ASC
                """)
            return rows.map { row -> SpeakerRow in
                let id: Int64 = row["id"]
                return SpeakerRow(
                    id: id,
                    name: row["name"],
                    displayLabel: row["label"] ?? "Speaker ?",
                    micCount: row["mic_count"] ?? 0,
                    systemCount: row["system_count"] ?? 0,
                    mergedInto: row["merged_into"],
                    isOwner: (ownerID == id)
                )
            }
        }
    }

    // MARK: - S4 segment indexing (live path)

    /// Carrier used by the merge layer to persist a finalized segment.
    /// Holds everything the segments-schema needs; the FTS5 virtual table
    /// stays in sync via `synchronize(withTable:)` triggers installed in
    /// the v3 migration.
    struct SegmentRecord: Sendable {
        let speakerID: Int64?
        let context: Context
        let sessionID: String
        let startedAt: Date
        let endedAt: Date
        let dateKey: String
        let text: String
        let provisional: Bool
    }

    /// Insert a finalized segment row. Called by the merge layer's
    /// `onForward` path so the segments table mirrors what landed on disk.
    /// Embeddings are still written separately by the resolver; that
    /// indirection is preserved so the resolver remains the sole writer of
    /// identity inferences (CLAUDE.md rule 8). Returns the inserted rowid.
    @discardableResult
    func indexSegment(_ record: SegmentRecord) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO segments
                        (date, start_ts, end_ts, source, session_id, speaker_id, provisional, text)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.dateKey,
                    record.startedAt.timeIntervalSince1970,
                    record.endedAt.timeIntervalSince1970,
                    record.context.rawValue,
                    record.sessionID,
                    record.speakerID,
                    record.provisional ? 1 : 0,
                    record.text
                ]
            )
            return db.lastInsertedRowID
        }
    }

    // MARK: - CP1 correction-pass surface

    /// One row from `segments` returned to the correction pass. Carries
    /// everything the offline pass needs to (a) decide whether to relabel
    /// and (b) build the file-rewrite transformation.
    struct StoredSegment: Sendable, Equatable {
        let id: Int64
        let dateKey: String
        let startedAt: Date
        let endedAt: Date
        let source: Context
        let sessionID: String
        let speakerID: Int64?
        let provisional: Bool
        let text: String
    }

    /// Every segment whose wall-clock start falls inside `range` for the
    /// given pipeline context. Used by `CorrectionPass.runOnce` to pull
    /// the in-window candidates against the offline re-diarization output.
    /// Includes both provisional and already-corrected rows so the
    /// correction pass can refine an earlier correction if it disagrees.
    func segmentsInRange(_ range: ClosedRange<Date>, context: Context) throws -> [StoredSegment] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, date, start_ts, end_ts, source, session_id,
                           speaker_id, provisional, text
                    FROM segments
                    WHERE source = ? AND start_ts >= ? AND start_ts <= ?
                    ORDER BY start_ts ASC
                    """,
                arguments: [
                    context.rawValue,
                    range.lowerBound.timeIntervalSince1970,
                    range.upperBound.timeIntervalSince1970
                ]
            )
            return rows.map { row -> StoredSegment in
                let dateKey: String = row["date"] ?? ""
                let startTs: Double = row["start_ts"]
                let endTs: Double = row["end_ts"]
                let sourceStr: String = row["source"] ?? "mic"
                let sessionID: String = row["session_id"] ?? ""
                let speakerID: Int64? = row["speaker_id"]
                let provisional: Int = row["provisional"] ?? 1
                let text: String = row["text"] ?? ""
                return StoredSegment(
                    id: row["id"],
                    dateKey: dateKey,
                    startedAt: Date(timeIntervalSince1970: startTs),
                    endedAt: Date(timeIntervalSince1970: endTs),
                    source: Context(rawValue: sourceStr) ?? context,
                    sessionID: sessionID,
                    speakerID: speakerID,
                    provisional: provisional != 0,
                    text: text
                )
            }
        }
    }

    /// One correction the offline pass wants to apply. Carries everything
    /// `applyCorrections` needs to update the row, build the relabel line
    /// for the Markdown rewriter, and emit a silent panel update.
    struct CorrectionUpdate: Sendable, Equatable {
        let segmentID: Int64
        let dateKey: String
        let startedAt: Date
        let source: Context
        let text: String
        /// Label the line currently carries on disk (e.g. "Speaker 3" or
        /// "Alice"). Used as the `oldLabel` in the relabel transformation
        /// so a stale rerun is idempotent.
        let oldLabel: String
        /// Persistent speaker id the resolver mapped this segment to.
        let newSpeakerID: Int64
        /// Display label for the new speaker (name if assigned, else
        /// "Speaker N"). Goes into both the DB row's effective render and
        /// the Markdown rewrite.
        let newLabel: String
    }

    /// Result handed back to the correction pass for metrics + live
    /// panel updates.
    struct CorrectionApplyOutcome: Sendable, Equatable {
        /// DB rows whose `speaker_id` actually changed.
        let relabeledSegmentIDs: [Int64]
        /// Markdown lines that flipped label inside the day's file.
        let relabeledLineCount: Int
        /// All applied updates (whether or not the speaker_id changed)
        /// so the caller can flip `provisional=0` in the live panel.
        let appliedUpdates: [CorrectionUpdate]
    }

    /// Apply a batch of corrections atomically per day: rewrite the day's
    /// Markdown via temp file + `replaceItemAt`, then update the affected
    /// `segments` rows (new `speaker_id`, `provisional = 0`). Same
    /// transactional pattern as S4 `renameSpeaker` — file swap runs inside
    /// `dbQueue.write` so a rewrite failure rolls back the DB updates.
    ///
    /// `transcriptFolder` is the writer's current folder (Settings may have
    /// changed it mid-run); `dateKey` is the day whose Markdown we touch.
    /// Updates for other days are still applied to the DB rows but skip
    /// the file rewrite — historical days' summary blocks may already be
    /// sealed; the segments index stays authoritative.
    func applyCorrections(
        _ updates: [CorrectionUpdate],
        dateKey: String,
        transcriptFolder: URL,
        writer: TranscriptWriter
    ) async throws -> CorrectionApplyOutcome {
        if updates.isEmpty {
            return CorrectionApplyOutcome(relabeledSegmentIDs: [], relabeledLineCount: 0, appliedUpdates: [])
        }

        let todayUpdates = updates.filter { $0.dateKey == dateKey }
        let target = transcriptFolder.appendingPathComponent("\(dateKey).md", isDirectory: false)
        let tempURL = transcriptFolder.appendingPathComponent("\(dateKey).md.correction.tmp", isDirectory: false)
        var rewriteCount = 0
        let needFileRewrite = FileManager.default.fileExists(atPath: target.path) && !todayUpdates.isEmpty

        if needFileRewrite {
            // Pause the writer so its open handle does not race the swap.
            // The same race window S4 carries — see `renameSpeaker` — is
            // accepted here too: live appends between pauseForRelabel and
            // the in-transaction replaceItemAt could be lost. Acceptable
            // because the correction pass only fires every 5 min and the
            // window is milliseconds. If this proves to bite, the fix is
            // to add an explicit "writer paused" gate the writer queues
            // appends behind.
            await writer.pauseForRelabel()

            let transformations: [RelabelTransformation] = todayUpdates.map { u in
                let time = SpeakerLibrary.timeFormatter.string(from: u.startedAt)
                return RelabelTransformation(
                    time: time,
                    source: u.source.rawValue,
                    oldLabel: u.oldLabel,
                    newLabel: u.newLabel,
                    text: u.text
                )
            }

            do {
                let original = try String(contentsOf: target, encoding: .utf8)
                let (rewritten, count) = SpeakerLibrary.applyRelabel(
                    source: original,
                    transformations: transformations
                )
                rewriteCount = count
                try rewritten.write(to: tempURL, atomically: false, encoding: .utf8)
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }
        }

        var relabeledIDs: [Int64] = []
        do {
            try await dbQueue.write { db in
                for update in updates {
                    // Pull the current speaker_id under the same transaction
                    // so the "did it actually change?" check is consistent
                    // with what we're about to write.
                    let current: Int64? = try Int64.fetchOne(
                        db,
                        sql: "SELECT speaker_id FROM segments WHERE id = ?",
                        arguments: [update.segmentID]
                    )
                    try db.execute(
                        sql: """
                            UPDATE segments
                            SET speaker_id = ?, provisional = 0
                            WHERE id = ?
                            """,
                        arguments: [update.newSpeakerID, update.segmentID]
                    )
                    if current != update.newSpeakerID {
                        relabeledIDs.append(update.segmentID)
                    }
                }
                if needFileRewrite {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: tempURL)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        return CorrectionApplyOutcome(
            relabeledSegmentIDs: relabeledIDs,
            relabeledLineCount: rewriteCount,
            appliedUpdates: updates
        )
    }

    // MARK: - S4 transactional renaming

    /// Result of a naming operation. Used by the UI to refresh state and
    /// by the IdentityResolver to invalidate its cache.
    struct RenameOutcome: Sendable, Equatable {
        let speakerID: Int64
        let oldLabel: String
        let newLabel: String
        /// Number of segments in today's Markdown that were rewritten.
        let relabeledSegmentCount: Int
    }

    /// Assign a name to a speaker and retroactively rewrite today's
    /// Markdown so every line tagged with the old display label flips to
    /// the new name. The whole operation is one DB transaction with the
    /// file rename inlined: `FileManager.replaceItemAt` runs inside
    /// `dbQueue.write`, so a rename failure throws and the SQL UPDATE
    /// rolls back. This is CLAUDE.md's "transactional speaker naming"
    /// rule at the data layer instead of relying on AppDelegate
    /// coordination.
    ///
    /// `writer` is the TranscriptWriter actor — we ask it to release its
    /// file handle first so the temp file we build can replace it cleanly.
    func renameSpeaker(
        speakerID: Int64,
        newName: String,
        todayDateKey: String,
        transcriptFolder: URL,
        writer: TranscriptWriter
    ) async throws -> RenameOutcome {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SpeakerLibraryError.invalidName
        }

        let oldLabel: String = try await dbQueue.read { db -> String in
            try String.fetchOne(
                db,
                sql: "SELECT COALESCE(name, display_label, 'Speaker ?') FROM speakers WHERE id = ?",
                arguments: [speakerID]
            ) ?? "Speaker ?"
        }

        // Read today's segments for this speaker so we know which lines
        // to rewrite. Match by (HH:mm:ss, source, text) so we are robust
        // to other speakers having identical timestamps.
        let todaySegments: [SegmentLineSummary] = try await dbQueue.read { db -> [SegmentLineSummary] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT start_ts, source, text FROM segments
                    WHERE speaker_id = ? AND date = ?
                    ORDER BY start_ts ASC
                    """,
                arguments: [speakerID, todayDateKey]
            )
            return rows.map { row in
                let ts: Double = row["start_ts"]
                let time = SpeakerLibrary.timeFormatter.string(from: Date(timeIntervalSince1970: ts))
                let source: String = row["source"] ?? "mic"
                let text: String = row["text"] ?? ""
                return SegmentLineSummary(time: time, source: source, text: text)
            }
        }

        // Build a relabel plan (old label → new label for every matching
        // line) before we touch the file. Writer pauses so its handle
        // is closed; the next write will reopen against the new file.
        await writer.pauseForRelabel()

        let target = transcriptFolder.appendingPathComponent("\(todayDateKey).md", isDirectory: false)
        let tempURL = transcriptFolder.appendingPathComponent("\(todayDateKey).md.relabel.tmp", isDirectory: false)
        var rewriteCount = 0
        let needFileRewrite = FileManager.default.fileExists(atPath: target.path) && !todaySegments.isEmpty

        if needFileRewrite {
            do {
                let original = try String(contentsOf: target, encoding: .utf8)
                let (rewritten, count) = SpeakerLibrary.applyRelabel(
                    source: original,
                    transformations: todaySegments.map { RelabelTransformation(time: $0.time, source: $0.source, oldLabel: oldLabel, newLabel: trimmed, text: $0.text) }
                )
                rewriteCount = count
                try rewritten.write(to: tempURL, atomically: false, encoding: .utf8)
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }
        }

        let targetPath = target
        let tempPath = tempURL
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE speakers SET name = ?, display_label = ? WHERE id = ?",
                    arguments: [trimmed, trimmed, speakerID]
                )
                if needFileRewrite {
                    _ = try FileManager.default.replaceItemAt(targetPath, withItemAt: tempPath)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        if AppSettings.ownerSpeakerIDValue == speakerID {
            AppSettings.ownerName = trimmed
        }

        return RenameOutcome(
            speakerID: speakerID,
            oldLabel: oldLabel,
            newLabel: trimmed,
            relabeledSegmentCount: rewriteCount
        )
    }

    // MARK: - S4 merge

    struct MergeOutcome: Sendable, Equatable {
        let sourceSpeakerID: Int64
        let destinationSpeakerID: Int64
        let newLabel: String
        let relabeledSegmentCount: Int
        let movedEmbeddingCount: Int
    }

    /// Merge `source` into `destination`. Embeddings and segments are
    /// reassigned to `destination`; `source.merged_into` is set so the
    /// row survives for audit but stops appearing in the live list.
    /// Today's Markdown lines that used to carry the source's display
    /// label are rewritten to the destination's display label, atomically
    /// with the DB UPDATE (same pattern as `renameSpeaker`).
    func mergeSpeakers(
        source: Int64,
        into destination: Int64,
        todayDateKey: String,
        transcriptFolder: URL,
        writer: TranscriptWriter
    ) async throws -> MergeOutcome {
        guard source != destination else { throw SpeakerLibraryError.cannotMergeIntoSelf }

        let labels: MergeLabels = try await dbQueue.read { db -> MergeLabels in
            let sLabel = try String.fetchOne(
                db,
                sql: "SELECT COALESCE(name, display_label, 'Speaker ?') FROM speakers WHERE id = ?",
                arguments: [source]
            ) ?? "Speaker ?"
            let dLabel = try String.fetchOne(
                db,
                sql: "SELECT COALESCE(name, display_label, 'Speaker ?') FROM speakers WHERE id = ?",
                arguments: [destination]
            ) ?? "Speaker ?"
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM embeddings WHERE speaker_id = ?",
                arguments: [source]
            ) ?? 0
            return MergeLabels(sourceLabel: sLabel, destLabel: dLabel, movedEmbeddings: count)
        }
        let sourceLabel = labels.sourceLabel
        let destLabel = labels.destLabel
        let movedEmbeddings = labels.movedEmbeddings

        // Audit snapshot. Compute max same/cross-context cosines
        // BEFORE the embedding UPDATE so source's evidence is still
        // attached to source. The values are persisted inside the
        // same write transaction as the merge itself; if the merge
        // rolls back, the audit row rolls back too. This is the only
        // moment retroactive analysis can read source's embeddings —
        // after the UPDATE they all belong to destination.
        let auditScores = try await computeMergeAuditScores(source: source, destination: destination)

        let todaySegments: [SegmentLineSummary] = try await dbQueue.read { db -> [SegmentLineSummary] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT start_ts, source, text FROM segments
                    WHERE speaker_id = ? AND date = ?
                    ORDER BY start_ts ASC
                    """,
                arguments: [source, todayDateKey]
            )
            return rows.map { row in
                let ts: Double = row["start_ts"]
                let time = SpeakerLibrary.timeFormatter.string(from: Date(timeIntervalSince1970: ts))
                let src: String = row["source"] ?? "mic"
                let text: String = row["text"] ?? ""
                return SegmentLineSummary(time: time, source: src, text: text)
            }
        }

        await writer.pauseForRelabel()

        let target = transcriptFolder.appendingPathComponent("\(todayDateKey).md", isDirectory: false)
        let tempURL = transcriptFolder.appendingPathComponent("\(todayDateKey).md.merge.tmp", isDirectory: false)
        var rewriteCount = 0
        let needFileRewrite = FileManager.default.fileExists(atPath: target.path) && !todaySegments.isEmpty

        if needFileRewrite {
            do {
                let original = try String(contentsOf: target, encoding: .utf8)
                let (rewritten, count) = SpeakerLibrary.applyRelabel(
                    source: original,
                    transformations: todaySegments.map { RelabelTransformation(time: $0.time, source: $0.source, oldLabel: sourceLabel, newLabel: destLabel, text: $0.text) }
                )
                rewriteCount = count
                try rewritten.write(to: tempURL, atomically: false, encoding: .utf8)
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }
        }

        let targetPath = target
        let tempPath = tempURL
        do {
            try await dbQueue.write { db in
                // Audit-snapshot row first — must happen before the
                // embedding reassignment so the scores attached here
                // reflect source's evidence at the moment of merge.
                try db.execute(
                    sql: """
                        INSERT INTO merge_audit (
                            source_speaker_id, destination_speaker_id, merged_at,
                            max_same_context_score, max_cross_context_score
                        ) VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        source,
                        destination,
                        SpeakerLibrary.timestampString(),
                        auditScores.maxSame,
                        auditScores.maxCross
                    ]
                )
                try db.execute(
                    sql: "UPDATE embeddings SET speaker_id = ? WHERE speaker_id = ?",
                    arguments: [destination, source]
                )
                try db.execute(
                    sql: "UPDATE segments SET speaker_id = ? WHERE speaker_id = ?",
                    arguments: [destination, source]
                )
                try db.execute(
                    sql: "UPDATE speakers SET merged_into = ? WHERE id = ?",
                    arguments: [destination, source]
                )
                // Resolver-telemetry ground-truth backfill. Every prior
                // match_decisions row that touched `source` (either as
                // the resolved speaker, or as the best-same / best-cross
                // candidate, or already-labeled with `source` as a prior
                // ground truth) now points to `destination` — the user
                // has effectively said "the right answer for these was
                // `destination` all along." Transitive merges (A→B→C)
                // bubble through the prior-ground-truth clause.
                try db.execute(
                    sql: """
                        UPDATE match_decisions
                        SET ground_truth_speaker_id = ?
                        WHERE ground_truth_speaker_id = ?
                           OR (ground_truth_speaker_id IS NULL AND (
                                  resolved_speaker_id = ?
                               OR best_same_speaker_id = ?
                               OR best_cross_speaker_id = ?
                           ))
                        """,
                    arguments: [destination, source, source, source, source]
                )
                if needFileRewrite {
                    _ = try FileManager.default.replaceItemAt(targetPath, withItemAt: tempPath)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        return MergeOutcome(
            sourceSpeakerID: source,
            destinationSpeakerID: destination,
            newLabel: destLabel,
            relabeledSegmentCount: rewriteCount,
            movedEmbeddingCount: movedEmbeddings
        )
    }

    // MARK: - S4 clear / delete / re-enroll

    /// Drop every embedding the speaker has accumulated. Used by the
    /// "Clear embeddings" action in `SpeakerLibraryWindow`. The speaker
    /// row stays; future utterances will accrue fresh embeddings.
    func clearEmbeddings(speakerID: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM embeddings WHERE speaker_id = ?",
                arguments: [speakerID]
            )
        }
    }

    /// Drop only one context's embeddings. Used internally by
    /// `reenrollOwner` so the system-side memory isn't blown away when
    /// the user redoes the 30 s mic capture.
    func clearEmbeddings(speakerID: Int64, context: Context) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM embeddings WHERE speaker_id = ? AND context = ?",
                arguments: [speakerID, context.rawValue]
            )
        }
    }

    /// Delete a speaker entirely. Embeddings go first; segments lose their
    /// speaker_id (FK is nullable, so future searches still surface the
    /// text). Today's on-disk file is intentionally NOT rewritten — the
    /// user picked a destructive action; the historical label stays in
    /// the Markdown alongside a "deleted" provenance. The whole DB side is
    /// one transaction.
    func deleteSpeaker(speakerID: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM embeddings WHERE speaker_id = ?",
                arguments: [speakerID]
            )
            try db.execute(
                sql: "UPDATE segments SET speaker_id = NULL WHERE speaker_id = ?",
                arguments: [speakerID]
            )
            try db.execute(
                sql: "DELETE FROM speakers WHERE id = ?",
                arguments: [speakerID]
            )
        }
    }

    /// Replace the owner's mic-context embeddings with a fresh enrollment
    /// vector. CLAUDE.md "transactional speaker naming" rule applied to
    /// re-enrollment: clear + insert in one transaction so we can never
    /// land in a half-empty state. The system-context embeddings (e.g.
    /// the user's voice as heard through a Teams call on speakers) are
    /// left alone — they were captured independently and are still
    /// valid.
    @discardableResult
    func reenrollOwner(name: String, embedding: [Float]) throws -> Int64 {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? (AppSettings.ownerName ?? "Me") : trimmedName
        let nowText = SpeakerLibrary.timestampString()
        guard !embedding.isEmpty else { throw SpeakerLibraryError.invalidEmbedding }
        let blob = embedding.withUnsafeBufferPointer { buffer in Data(buffer: buffer) }

        let speakerID: Int64 = try dbQueue.write { db in
            let id: Int64
            if let existing = AppSettings.ownerSpeakerIDValue,
               try Int64.fetchOne(db, sql: "SELECT id FROM speakers WHERE id = ?", arguments: [existing]) != nil {
                try db.execute(
                    sql: "UPDATE speakers SET name = ?, display_label = ? WHERE id = ?",
                    arguments: [displayName, displayName, existing]
                )
                id = existing
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO speakers (name, created_at, merged_into, display_label)
                        VALUES (?, ?, NULL, ?)
                        """,
                    arguments: [displayName, nowText, displayName]
                )
                id = db.lastInsertedRowID
            }

            try db.execute(
                sql: "DELETE FROM embeddings WHERE speaker_id = ? AND context = ?",
                arguments: [id, Context.mic.rawValue]
            )
            try db.execute(
                sql: """
                    INSERT INTO embeddings (speaker_id, context, vector, quality, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [id, Context.mic.rawValue, blob, 1.0, nowText]
            )
            return id
        }

        AppSettings.ownerName = displayName
        AppSettings.ownerSpeakerIDValue = speakerID
        return speakerID
    }

    // MARK: - S4 FTS5 search + log

    struct SearchHit: Sendable, Identifiable, Equatable {
        let id: Int64
        let dateKey: String
        let startedAt: Date
        let endedAt: Date
        let source: Context
        let speakerID: Int64?
        let speakerLabel: String
        let text: String
    }

    /// Filters for the cross-transcript search window. All fields are
    /// optional; `nil` (or empty) means "no constraint" so a freshly-opened
    /// window with no filters set still returns hits from every session
    /// ever recorded. The segments / FTS5 index is the persistent store
    /// (one row per finalized segment from either pipeline, written by the
    /// merge layer's `onForward` since S4), so this is the only query path
    /// callers need for whole-history search.
    struct SearchFilters: Sendable, Equatable {
        var startDate: Date?
        var endDate: Date?
        var speakerIDs: [Int64]?
        var sources: Set<Context>?

        static let none = SearchFilters()
    }

    /// Run an FTS5 query against `segments_fts`. The pattern is built with
    /// `FTS5Pattern(matchingAllTokensIn:)` so the user can paste plain
    /// text without worrying about FTS5 grammar. Results are sorted by
    /// `bm25` rank (best match first). The hit list is capped at `limit`
    /// to keep the panel snappy.
    ///
    /// `filters` narrows by wall-clock date range, persistent speaker id,
    /// and source pipeline (mic/system). An empty `query` with non-empty
    /// filters returns the most-recent matching segments ordered by
    /// `start_ts DESC` so the cross-transcript search window can act as a
    /// browse-by-filter view too.
    func searchSegments(
        query: String,
        filters: SearchFilters = .none,
        limit: Int = 200
    ) throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesFts = !trimmed.isEmpty
        let pattern: FTS5Pattern?
        if usesFts {
            guard let p = FTS5Pattern(matchingAllTokensIn: trimmed) else { return [] }
            pattern = p
        } else {
            pattern = nil
            // Guard against an empty-query, empty-filter call — that would
            // dump the entire segments table into memory. The window only
            // sends an empty-query request when at least one filter is set;
            // enforce here too.
            let noFilters = filters.startDate == nil
                && filters.endDate == nil
                && (filters.speakerIDs?.isEmpty ?? true)
                && (filters.sources?.isEmpty ?? true)
            if noFilters { return [] }
        }

        return try dbQueue.read { db in
            var where_: [String] = []
            var args: [(any DatabaseValueConvertible)?] = []
            if usesFts, let pattern {
                where_.append("f.text MATCH ?")
                args.append(pattern)
            }
            if let start = filters.startDate {
                where_.append("s.start_ts >= ?")
                args.append(start.timeIntervalSince1970)
            }
            if let end = filters.endDate {
                where_.append("s.start_ts <= ?")
                args.append(end.timeIntervalSince1970)
            }
            if let speakerIDs = filters.speakerIDs, !speakerIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: speakerIDs.count).joined(separator: ",")
                where_.append("s.speaker_id IN (\(placeholders))")
                for id in speakerIDs { args.append(id) }
            }
            if let sources = filters.sources, !sources.isEmpty {
                let placeholders = Array(repeating: "?", count: sources.count).joined(separator: ",")
                where_.append("s.source IN (\(placeholders))")
                // Stable order so the placeholder/argument count agrees.
                for source in sources.sorted(by: { $0.rawValue < $1.rawValue }) {
                    args.append(source.rawValue)
                }
            }
            args.append(limit)

            let whereClause = where_.isEmpty ? "" : "WHERE " + where_.joined(separator: " AND ")
            let orderClause = usesFts ? "ORDER BY bm25(segments_fts)" : "ORDER BY s.start_ts DESC"
            let fromClause = usesFts
                ? "FROM segments_fts f JOIN segments s ON s.id = f.rowid LEFT JOIN speakers sp ON sp.id = s.speaker_id"
                : "FROM segments s LEFT JOIN speakers sp ON sp.id = s.speaker_id"

            let sql = """
                SELECT s.id AS id,
                       s.date AS date,
                       s.start_ts AS start_ts,
                       s.end_ts AS end_ts,
                       s.source AS source,
                       s.speaker_id AS speaker_id,
                       s.text AS text,
                       COALESCE(sp.name, sp.display_label, 'Speaker ?') AS label
                \(fromClause)
                \(whereClause)
                \(orderClause)
                LIMIT ?
                """

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                let ts: Double = row["start_ts"]
                let endTs: Double = row["end_ts"] ?? ts
                let srcStr: String = row["source"] ?? "mic"
                return SearchHit(
                    id: row["id"],
                    dateKey: row["date"] ?? "",
                    startedAt: Date(timeIntervalSince1970: ts),
                    endedAt: Date(timeIntervalSince1970: endTs),
                    source: Context(rawValue: srcStr) ?? .mic,
                    speakerID: row["speaker_id"],
                    speakerLabel: row["label"] ?? "Speaker ?",
                    text: row["text"] ?? ""
                )
            }
        }
    }

    /// PRD R8: every query is logged locally so the daily summary can
    /// report the search count and we can decide whether the AI layer
    /// over transcripts is worth building.
    func logSearch(query: String, resultCount: Int, at date: Date = Date()) throws {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ts = SpeakerLibrary.timestampString(date)
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO search_log (query, result_count, executed_at) VALUES (?, ?, ?)",
                arguments: [trimmed, resultCount, ts]
            )
        }
    }

    /// Total searches the user has ever run. Useful for the future AI
    /// layer decision in PRD R8.
    func totalSearchCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_log") ?? 0
        }
    }

    // MARK: - S4 relabel helpers (nonisolated so tests can hit them)

    /// One row from the segments table reduced to the fields the file
    /// rewriter needs. Sendable because the GRDB async read closure
    /// requires it.
    struct SegmentLineSummary: Sendable, Equatable {
        let time: String
        let source: String
        let text: String
    }

    /// Internal carrier for `mergeSpeakers` so the async `dbQueue.read`
    /// can return a single Sendable value.
    struct MergeLabels: Sendable {
        let sourceLabel: String
        let destLabel: String
        let movedEmbeddings: Int
    }

    /// One relabel instruction: rewrite the line at this (time, source,
    /// text) so its speaker label flips from `oldLabel` to `newLabel`.
    struct RelabelTransformation: Sendable, Equatable {
        let time: String
        let source: String
        let oldLabel: String
        let newLabel: String
        let text: String
    }

    /// Apply a list of relabel transformations to a Markdown transcript
    /// body. Each transformation targets exactly one line whose prefix
    /// is `[time] [source] oldLabel: text`. Lines that don't match a
    /// transformation pass through unchanged. Returns the rewritten body
    /// and the count of lines actually changed.
    nonisolated static func applyRelabel(
        source: String,
        transformations: [RelabelTransformation]
    ) -> (String, Int) {
        // Build a lookup: (time, source, text) → (oldLabel, newLabel).
        // Including the segment text means two speakers with the same
        // HH:MM:SS can't accidentally rewrite each other.
        struct Key: Hashable { let time: String; let source: String; let text: String }
        var lookup: [Key: (String, String)] = [:]
        for t in transformations {
            lookup[Key(time: t.time, source: t.source, text: t.text)] = (t.oldLabel, t.newLabel)
        }

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var changed = 0
        let rewrittenLines: [String] = lines.map { line in
            guard let parsed = parseTranscriptLine(line) else { return line }
            let key = Key(time: parsed.time, source: parsed.source, text: parsed.text)
            guard let (oldLabel, newLabel) = lookup[key] else { return line }
            // Only rewrite if the old label still matches what's in the file.
            // Defends against re-running the same rename twice (the second
            // pass becomes a no-op).
            guard parsed.label == oldLabel else { return line }
            changed += 1
            return "[\(parsed.time)] [\(parsed.source)] \(newLabel): \(parsed.text)"
        }
        return (rewrittenLines.joined(separator: "\n"), changed)
    }

    /// Parse a single transcript line of the canonical form. Returns nil
    /// for headers, markers (`paused 14:00:00`), the summary block, or
    /// anything else we don't want to touch.
    nonisolated static func parseTranscriptLine(_ line: String) -> (time: String, source: String, label: String, text: String)? {
        // Must start with "[HH:MM:SS] [source] "
        guard line.hasPrefix("[") else { return nil }
        // [HH:MM:SS]
        let closeBracket1 = line.firstIndex(of: "]") ?? line.endIndex
        guard closeBracket1 < line.endIndex else { return nil }
        let timeSlice = line[line.index(after: line.startIndex)..<closeBracket1]
        let time = String(timeSlice)
        guard time.count == 8, time[time.index(time.startIndex, offsetBy: 2)] == ":" else { return nil }

        // " [source]"
        var idx = line.index(after: closeBracket1)
        while idx < line.endIndex, line[idx] == " " { idx = line.index(after: idx) }
        guard idx < line.endIndex, line[idx] == "[" else { return nil }
        idx = line.index(after: idx)
        guard let closeBracket2 = line[idx...].firstIndex(of: "]") else { return nil }
        let source = String(line[idx..<closeBracket2])
        guard source == "mic" || source == "system" else { return nil }

        // " LABEL: text"
        var rest = line[line.index(after: closeBracket2)...]
        while !rest.isEmpty, rest.first == " " { rest = rest.dropFirst() }
        // First ": " separates label from text. Label may itself contain
        // colons (e.g. "Dr. Foo: nickname") so we use range(of:).
        guard let labelEnd = rest.range(of: ": ") else { return nil }
        let label = String(rest[..<labelEnd.lowerBound])
        let text = String(rest[labelEnd.upperBound...])
        return (time, source, label, text)
    }

    /// Parse a single transcript line of the bookmark form
    /// `bookmark HH:MM:SS - LABEL`. Returns nil for anything else
    /// (canonical segments, headers, pause/resume/gap markers). The
    /// label is everything after the first ` - ` so embedded hyphens
    /// inside the label survive round-trip.
    nonisolated static func parseBookmarkLine(_ line: String) -> (time: String, label: String)? {
        let prefix = "bookmark "
        guard line.hasPrefix(prefix) else { return nil }
        let afterPrefix = line.dropFirst(prefix.count)
        // HH:MM:SS — exact 8 chars, colon at indices 2 and 5.
        guard afterPrefix.count >= 8 else { return nil }
        let time = String(afterPrefix.prefix(8))
        guard time.count == 8,
              time[time.index(time.startIndex, offsetBy: 2)] == ":",
              time[time.index(time.startIndex, offsetBy: 5)] == ":" else { return nil }
        let rest = afterPrefix.dropFirst(8)
        let sep = " - "
        guard rest.hasPrefix(sep) else { return nil }
        let label = String(rest.dropFirst(sep.count))
        guard !label.isEmpty else { return nil }
        return (time, label)
    }

    // MARK: - Sessions and bookmarks

    /// A bounded stretch of listening. `endedAt == nil` while the
    /// session is open. `label` is user-supplied (currently only set via
    /// a bookmark drop that mints a new session).
    struct Session: Sendable, Equatable, Identifiable {
        enum Kind: String, Sendable, CaseIterable {
            case call
            case ambient
        }
        enum Source: String, Sendable, CaseIterable {
            case mic
            case system
            case both
        }
        let id: Int64
        let type: Kind
        let source: Source
        let label: String?
        let startedAt: Date
        let endedAt: Date?
    }

    /// A user-named, timestamped boundary. Always belongs to a session
    /// (a bookmark drop either annotates an open session or starts a
    /// fresh one, so `sessionID` is non-nil for every freshly-inserted
    /// row; the FK is nullable purely so a future "delete session" path
    /// can null out orphans rather than cascade-delete bookmarks).
    struct Bookmark: Sendable, Equatable, Identifiable {
        let id: Int64
        let sessionID: Int64?
        let label: String
        let capturedAt: Date
    }

    /// Result of a bookmark drop. `bookmark` is the row inserted; if
    /// no session was open at `capturedAt`, a fresh ambient session was
    /// minted with the bookmark's label, and `createdSession` is true.
    struct BookmarkOutcome: Sendable, Equatable {
        let bookmark: Bookmark
        let session: Session
        let createdSession: Bool
    }

    enum SessionError: LocalizedError {
        case emptyLabel

        var errorDescription: String? {
            switch self {
            case .emptyLabel: return "Bookmark label cannot be empty."
            }
        }
    }

    /// Insert a new session row. Returns the row id so the live tracker
    /// can close it on pipeline stop. Caller is responsible for calling
    /// `closeSession` — leaving rows open is benign (they get closed at
    /// the next launch by `closeOrphanedOpenSessions`) but the timeline
    /// UX prefers a clean ended_at.
    @discardableResult
    func openSession(
        type: Session.Kind,
        source: Session.Source,
        label: String? = nil,
        startedAt: Date = Date()
    ) throws -> Int64 {
        let nowText = SpeakerLibrary.timestampString()
        return try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (type, source, label, started_at, ended_at, created_at)
                    VALUES (?, ?, ?, ?, NULL, ?)
                    """,
                arguments: [
                    type.rawValue,
                    source.rawValue,
                    label,
                    startedAt.timeIntervalSince1970,
                    nowText
                ]
            )
            return db.lastInsertedRowID
        }
    }

    /// Close a session row by setting `ended_at`. A re-close just
    /// overwrites the existing ended_at — used by
    /// `closeOrphanedOpenSessions` at boot, and tolerable if the live
    /// tracker hits a duplicate status event.
    func closeSession(id: Int64, endedAt: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET ended_at = ? WHERE id = ?",
                arguments: [endedAt.timeIntervalSince1970, id]
            )
        }
    }

    /// Most-recently-started open session matching `source`, or nil if
    /// none. The live tracker uses this on boot so a pipeline that was
    /// already counted as "started" by a quick subsequent pause doesn't
    /// open a second row.
    func currentOpenSession(source: Session.Source) throws -> Session? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, type, source, label, started_at, ended_at
                    FROM sessions
                    WHERE source = ? AND ended_at IS NULL
                    ORDER BY started_at DESC
                    LIMIT 1
                    """,
                arguments: [source.rawValue]
            )
            return row.flatMap(Self.session(from:))
        }
    }

    /// Most-recently-started open session whose started_at <= `moment`.
    /// Used by `addBookmark` to decide attach-vs-mint.
    func openSessionContaining(_ moment: Date) throws -> Session? {
        let ts = moment.timeIntervalSince1970
        return try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, type, source, label, started_at, ended_at
                    FROM sessions
                    WHERE ended_at IS NULL AND started_at <= ?
                    ORDER BY started_at DESC
                    LIMIT 1
                    """,
                arguments: [ts]
            )
            return row.flatMap(Self.session(from:))
        }
    }

    /// All sessions, most-recent-first. Used by the upcoming timeline
    /// UI and by tests that inspect the backfill result.
    func listSessions(limit: Int = 200) throws -> [Session] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, type, source, label, started_at, ended_at
                    FROM sessions
                    ORDER BY started_at DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
            return rows.compactMap(Self.session(from:))
        }
    }

    /// Close every still-open session row at boot. Idempotent: rows
    /// with non-nil ended_at are untouched. Sessions opened in the
    /// future (clock skew) are also skipped so we don't clobber a row
    /// that the current process just opened.
    func closeOrphanedOpenSessions(closingAt: Date = Date()) throws {
        let nowTs = closingAt.timeIntervalSince1970
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE sessions
                    SET ended_at = ?
                    WHERE ended_at IS NULL AND started_at <= ?
                    """,
                arguments: [nowTs, nowTs]
            )
        }
    }

    /// Drop a timestamped, named bookmark. If an open session covers
    /// `capturedAt`, the bookmark is attached to it. Otherwise a fresh
    /// ambient session (source = mic) is minted with the bookmark's
    /// label, started_at = capturedAt, ended_at NULL. Throws
    /// `SessionError.emptyLabel` if the trimmed label is empty.
    @discardableResult
    func addBookmark(label: String, capturedAt: Date = Date()) throws -> BookmarkOutcome {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SessionError.emptyLabel }
        let capturedTs = capturedAt.timeIntervalSince1970
        let nowText = SpeakerLibrary.timestampString()

        return try dbQueue.write { db in
            let openRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, type, source, label, started_at, ended_at
                    FROM sessions
                    WHERE ended_at IS NULL AND started_at <= ?
                    ORDER BY started_at DESC
                    LIMIT 1
                    """,
                arguments: [capturedTs]
            )

            let session: Session
            let created: Bool
            if let openRow, let existing = Self.session(from: openRow) {
                session = existing
                created = false
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO sessions (type, source, label, started_at, ended_at, created_at)
                        VALUES ('ambient', 'mic', ?, ?, NULL, ?)
                        """,
                    arguments: [trimmed, capturedTs, nowText]
                )
                let newID = db.lastInsertedRowID
                session = Session(
                    id: newID,
                    type: .ambient,
                    source: .mic,
                    label: trimmed,
                    startedAt: capturedAt,
                    endedAt: nil
                )
                created = true
            }

            try db.execute(
                sql: """
                    INSERT INTO bookmarks (session_id, label, captured_at, created_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [session.id, trimmed, capturedTs, nowText]
            )
            let bookmarkID = db.lastInsertedRowID
            let bookmark = Bookmark(
                id: bookmarkID,
                sessionID: session.id,
                label: trimmed,
                capturedAt: capturedAt
            )
            return BookmarkOutcome(bookmark: bookmark, session: session, createdSession: created)
        }
    }

    /// Bookmarks ordered by capture time. When `sessionID` is non-nil
    /// the result is filtered to that session and ordered ASC (so the
    /// timeline can render them in stroll order); otherwise the result
    /// is DESC across all sessions (newest first).
    func listBookmarks(sessionID: Int64? = nil, limit: Int = 500) throws -> [Bookmark] {
        try dbQueue.read { db in
            let rows: [Row]
            if let sessionID {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, session_id, label, captured_at
                        FROM bookmarks
                        WHERE session_id = ?
                        ORDER BY captured_at ASC
                        LIMIT ?
                        """,
                    arguments: [sessionID, limit]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, session_id, label, captured_at
                        FROM bookmarks
                        ORDER BY captured_at DESC
                        LIMIT ?
                        """,
                    arguments: [limit]
                )
            }
            return rows.compactMap(Self.bookmark(from:))
        }
    }

    /// Re-run the v4 backfill against the current `segments` table.
    /// Idempotent only in the trivial sense that running it twice
    /// produces duplicate session rows for the same (source,
    /// session_id) groups — used by tests and exposed for a future
    /// admin path. Returns the number of rows inserted.
    @discardableResult
    func backfillSessionsFromSegments() throws -> Int {
        let nowText = SpeakerLibrary.timestampString()
        return try dbQueue.write { db in
            let before = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions") ?? 0
            try db.execute(
                sql: """
                    INSERT INTO sessions (type, source, started_at, ended_at, created_at)
                    SELECT
                        CASE WHEN source = 'system' THEN 'call' ELSE 'ambient' END,
                        source,
                        MIN(start_ts),
                        MAX(end_ts),
                        ?
                    FROM segments
                    WHERE session_id IS NOT NULL AND session_id <> ''
                    GROUP BY source, session_id
                    """,
                arguments: [nowText]
            )
            let after = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions") ?? 0
            return after - before
        }
    }

    // MARK: - Session row mapping

    private static func session(from row: Row) -> Session? {
        let id: Int64 = row["id"]
        guard let typeStr: String = row["type"],
              let type = Session.Kind(rawValue: typeStr),
              let sourceStr: String = row["source"],
              let source = Session.Source(rawValue: sourceStr) else {
            return nil
        }
        let label: String? = row["label"]
        let startedTs: Double = row["started_at"]
        let endedTs: Double? = row["ended_at"]
        return Session(
            id: id,
            type: type,
            source: source,
            label: label,
            startedAt: Date(timeIntervalSince1970: startedTs),
            endedAt: endedTs.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private static func bookmark(from row: Row) -> Bookmark? {
        let id: Int64 = row["id"]
        let sessionID: Int64? = row["session_id"]
        let label: String = row["label"] ?? ""
        let capturedTs: Double = row["captured_at"]
        return Bookmark(
            id: id,
            sessionID: sessionID,
            label: label,
            capturedAt: Date(timeIntervalSince1970: capturedTs)
        )
    }

    // MARK: - Timeline (day-scoped sessions + bookmarks)

    /// Sessions intersecting a single day key plus every bookmark whose
    /// capture moment falls inside that day. The timeline window calls
    /// this once per visible day. Sessions that straddle midnight are
    /// returned for every day they touch — the timeline view clips them
    /// to the visible day.
    struct DayTimeline: Sendable, Equatable {
        let dateKey: String
        let dayStart: Date
        let dayEnd: Date
        let sessions: [Session]
        let bookmarks: [Bookmark]
    }

    /// Wraps the SQL needed by the timeline window. Day boundaries are
    /// derived in local time so the on-disk Markdown's day key (also
    /// local-time, via TranscriptWriter) and the timeline agree.
    func timelineForDay(_ dateKey: String) throws -> DayTimeline {
        guard let dayStart = SpeakerLibrary.dayKeyFormatter.date(from: dateKey) else {
            throw RedactionError.invalidDayKey
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            throw RedactionError.invalidDayKey
        }
        let s = dayStart.timeIntervalSince1970
        let e = dayEnd.timeIntervalSince1970

        return try dbQueue.read { db in
            let sessionRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, type, source, label, started_at, ended_at
                    FROM sessions
                    WHERE started_at < ?
                      AND (ended_at IS NULL OR ended_at > ?)
                    ORDER BY started_at ASC
                    """,
                arguments: [e, s]
            )
            let sessions = sessionRows.compactMap(Self.session(from:))

            let bookmarkRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, session_id, label, captured_at
                    FROM bookmarks
                    WHERE captured_at >= ? AND captured_at < ?
                    ORDER BY captured_at ASC
                    """,
                arguments: [s, e]
            )
            let bookmarks = bookmarkRows.compactMap(Self.bookmark(from:))

            return DayTimeline(
                dateKey: dateKey,
                dayStart: dayStart,
                dayEnd: dayEnd,
                sessions: sessions,
                bookmarks: bookmarks
            )
        }
    }

    /// Date keys (YYYY-MM-DD) that have either a session row or a bookmark
    /// row. Used by the timeline window to populate the date picker's
    /// "go to earliest" button without scanning every day on disk. Local
    /// midnight bucket per row.
    func datesWithTimelineActivity() throws -> [String] {
        try dbQueue.read { db in
            var keys = Set<String>()
            let sessionStarts = try Double.fetchAll(
                db, sql: "SELECT started_at FROM sessions"
            )
            for ts in sessionStarts {
                keys.insert(SpeakerLibrary.dayKeyFormatter.string(from: Date(timeIntervalSince1970: ts)))
            }
            let bookmarkStamps = try Double.fetchAll(
                db, sql: "SELECT captured_at FROM bookmarks"
            )
            for ts in bookmarkStamps {
                keys.insert(SpeakerLibrary.dayKeyFormatter.string(from: Date(timeIntervalSince1970: ts)))
            }
            return keys.sorted()
        }
    }

    /// Look up the first segment whose start is inside `[start, end]` for
    /// the given source pipeline. Returned as a `Focus` triplet the
    /// `TranscriptReaderModel` can match. The timeline window calls this
    /// when the user clicks a session block so the reader opens scrolled
    /// to that session's first utterance.
    struct FirstSegmentFocus: Sendable, Equatable {
        let dateKey: String
        let time: String
        let source: String
        let text: String
    }

    func firstSegmentFocus(
        start: Date,
        end: Date,
        source: Context
    ) throws -> FirstSegmentFocus? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT date, start_ts, source, text
                    FROM segments
                    WHERE start_ts >= ? AND start_ts <= ? AND source = ?
                    ORDER BY start_ts ASC
                    LIMIT 1
                    """,
                arguments: [
                    start.timeIntervalSince1970,
                    end.timeIntervalSince1970,
                    source.rawValue
                ]
            )
            guard let row else { return nil }
            let ts: Double = row["start_ts"]
            let time = SpeakerLibrary.timeFormatter.string(from: Date(timeIntervalSince1970: ts))
            return FirstSegmentFocus(
                dateKey: row["date"] ?? "",
                time: time,
                source: row["source"] ?? source.rawValue,
                text: row["text"] ?? ""
            )
        }
    }

    // MARK: - Curation (redaction)

    /// One curation-preview row. Returned in chronological order so the
    /// confirmation sheet can render the lines that are about to disappear.
    struct RedactionPreviewRow: Sendable, Equatable, Identifiable {
        let id: Int64
        let dateKey: String
        let startedAt: Date
        let source: Context
        let speakerLabel: String
        let text: String
    }

    /// Summary of the curation operation. `daysAffected` lists every
    /// `YYYY-MM-DD` whose Markdown file was rewritten so the caller can
    /// reopen any in-flight reader windows.
    struct RedactionOutcome: Sendable, Equatable {
        let segmentsDeleted: Int
        let bookmarksDeleted: Int
        let markdownLinesDeleted: Int
        let daysAffected: [String]
    }

    /// One drop instruction for the file rewriter. Matches a single line
    /// by its canonical `[HH:MM:SS] [source] LABEL: text` prefix-and-tail.
    struct RedactionLine: Sendable, Equatable {
        let time: String
        let source: String
        let text: String
    }

    enum RedactionError: LocalizedError {
        case invalidRange
        case invalidDayKey

        var errorDescription: String? {
            switch self {
            case .invalidRange: return "Redaction end must be at or after start."
            case .invalidDayKey: return "Could not parse the supplied day key."
            }
        }
    }

    /// Read-only listing of every segment that `redactRange` would remove
    /// given the same arguments. Used by the redaction sheet to show a
    /// preview count and the lines themselves before the user confirms.
    func previewRedaction(
        start: Date,
        end: Date,
        sources: Set<Context>? = nil,
        limit: Int = 500
    ) throws -> [RedactionPreviewRow] {
        guard start <= end else { throw RedactionError.invalidRange }
        return try dbQueue.read { db in
            var where_: [String] = ["s.start_ts >= ?", "s.start_ts <= ?"]
            var args: [(any DatabaseValueConvertible)?] = [
                start.timeIntervalSince1970,
                end.timeIntervalSince1970
            ]
            if let sources, !sources.isEmpty {
                let placeholders = Array(repeating: "?", count: sources.count).joined(separator: ",")
                where_.append("s.source IN (\(placeholders))")
                for src in sources.sorted(by: { $0.rawValue < $1.rawValue }) {
                    args.append(src.rawValue)
                }
            }
            args.append(limit)
            let sql = """
                SELECT s.id AS id,
                       s.date AS date,
                       s.start_ts AS start_ts,
                       s.source AS source,
                       s.text AS text,
                       COALESCE(sp.name, sp.display_label, 'Speaker ?') AS label
                FROM segments s
                LEFT JOIN speakers sp ON sp.id = s.speaker_id
                WHERE \(where_.joined(separator: " AND "))
                ORDER BY s.start_ts ASC
                LIMIT ?
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                let ts: Double = row["start_ts"]
                let srcStr: String = row["source"] ?? "mic"
                return RedactionPreviewRow(
                    id: row["id"],
                    dateKey: row["date"] ?? "",
                    startedAt: Date(timeIntervalSince1970: ts),
                    source: Context(rawValue: srcStr) ?? .mic,
                    speakerLabel: row["label"] ?? "Speaker ?",
                    text: row["text"] ?? ""
                )
            }
        }
    }

    /// Count of bookmarks that fall inside the redaction window so the
    /// preview UI can warn that they will be removed too.
    func previewBookmarkRedactionCount(start: Date, end: Date) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM bookmarks
                    WHERE captured_at >= ? AND captured_at <= ?
                    """,
                arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970]
            ) ?? 0
        }
    }

    /// Permanently scrub everything inside `[start, end]`:
    ///
    /// 1. Every Markdown line whose `[HH:MM:SS] [source] LABEL: text`
    ///    matches an in-range segment is dropped from the day's `.md`.
    /// 2. The corresponding `segments` rows are DELETEd — the
    ///    `segments_fts` virtual table's GRDB-installed triggers cascade
    ///    the delete to FTS5 inside the same write, so no orphaned search
    ///    hits survive (CLAUDE.md rule 4 + curation requirement).
    /// 3. Bookmarks captured inside the same window are deleted too — a
    ///    bookmark referring to redacted content shouldn't outlive its
    ///    referent.
    ///
    /// The file rewrite (`FileManager.replaceItemAt`) runs inside the
    /// same `dbQueue.write { … }` as the SQL DELETEs, so if either side
    /// throws the whole operation rolls back. `writer.pauseForRelabel()`
    /// is called first so the day's open append handle releases before
    /// the swap. Sessions rows are intentionally left alone: a redacted
    /// session still happened — the user can drop a fresh range if they
    /// want the bounding metadata gone too.
    ///
    /// Optional `sources` narrows the delete (e.g. "redact mic but leave
    /// system audio segments") so the timeline's per-block redact path
    /// can target just one pipeline.
    func redactRange(
        start: Date,
        end: Date,
        sources: Set<Context>? = nil,
        transcriptFolder: URL,
        writer: TranscriptWriter
    ) async throws -> RedactionOutcome {
        guard start <= end else { throw RedactionError.invalidRange }
        let startTs = start.timeIntervalSince1970
        let endTs = end.timeIntervalSince1970

        // 1. Pull in-range segments so we know which Markdown lines to
        // drop on each affected day.
        struct DropRow: Sendable {
            let dateKey: String
            let time: String
            let source: String
            let text: String
        }
        let drops: [DropRow] = try await dbQueue.read { db in
            var sql = """
                SELECT date, start_ts, source, text
                FROM segments
                WHERE start_ts >= ? AND start_ts <= ?
                """
            var args: [(any DatabaseValueConvertible)?] = [startTs, endTs]
            if let sources, !sources.isEmpty {
                let placeholders = Array(repeating: "?", count: sources.count).joined(separator: ",")
                sql += " AND source IN (\(placeholders))"
                for src in sources.sorted(by: { $0.rawValue < $1.rawValue }) {
                    args.append(src.rawValue)
                }
            }
            sql += " ORDER BY start_ts ASC"
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                let ts: Double = row["start_ts"]
                let time = SpeakerLibrary.timeFormatter.string(from: Date(timeIntervalSince1970: ts))
                return DropRow(
                    dateKey: row["date"] ?? "",
                    time: time,
                    source: row["source"] ?? "mic",
                    text: row["text"] ?? ""
                )
            }
        }

        // 2. Stage rewritten Markdown for every affected day.
        let grouped = Dictionary(grouping: drops, by: \.dateKey)
        await writer.pauseForRelabel()

        var stagedRewrites: [(target: URL, temp: URL)] = []
        var totalLinesDropped = 0

        do {
            for (dateKey, dayDrops) in grouped {
                guard !dateKey.isEmpty else { continue }
                let target = transcriptFolder.appendingPathComponent("\(dateKey).md", isDirectory: false)
                guard FileManager.default.fileExists(atPath: target.path) else { continue }
                let tempURL = transcriptFolder.appendingPathComponent("\(dateKey).md.redact.tmp", isDirectory: false)
                let original = try String(contentsOf: target, encoding: .utf8)
                let dropLines = dayDrops.map {
                    RedactionLine(time: $0.time, source: $0.source, text: $0.text)
                }
                let (rewritten, droppedCount) = SpeakerLibrary.applyRedaction(
                    source: original,
                    drops: dropLines
                )
                totalLinesDropped += droppedCount
                try rewritten.write(to: tempURL, atomically: false, encoding: .utf8)
                stagedRewrites.append((target: target, temp: tempURL))
            }
        } catch {
            for entry in stagedRewrites {
                try? FileManager.default.removeItem(at: entry.temp)
            }
            throw error
        }

        // 3. One transaction: SQL DELETEs (FTS5 cascades via GRDB
        // sync triggers) + file swaps. If anything throws, every staged
        // rewrite is removed below and the DB rolls back to pre-state.
        let rewrites = stagedRewrites
        var segmentDeleteCount = 0
        var bookmarkDeleteCount = 0
        let filterSources = sources

        do {
            try await dbQueue.write { db in
                var sql = "DELETE FROM segments WHERE start_ts >= ? AND start_ts <= ?"
                var args: [(any DatabaseValueConvertible)?] = [startTs, endTs]
                if let filterSources, !filterSources.isEmpty {
                    let placeholders = Array(repeating: "?", count: filterSources.count).joined(separator: ",")
                    sql += " AND source IN (\(placeholders))"
                    for src in filterSources.sorted(by: { $0.rawValue < $1.rawValue }) {
                        args.append(src.rawValue)
                    }
                }
                try db.execute(sql: sql, arguments: StatementArguments(args))
                segmentDeleteCount = db.changesCount

                try db.execute(
                    sql: """
                        DELETE FROM bookmarks
                        WHERE captured_at >= ? AND captured_at <= ?
                        """,
                    arguments: [startTs, endTs]
                )
                bookmarkDeleteCount = db.changesCount

                for entry in rewrites {
                    _ = try FileManager.default.replaceItemAt(entry.target, withItemAt: entry.temp)
                }
            }
        } catch {
            for entry in stagedRewrites {
                try? FileManager.default.removeItem(at: entry.temp)
            }
            throw error
        }

        return RedactionOutcome(
            segmentsDeleted: segmentDeleteCount,
            bookmarksDeleted: bookmarkDeleteCount,
            markdownLinesDeleted: totalLinesDropped,
            daysAffected: grouped.keys.sorted()
        )
    }

    /// Strip lines whose `(time, source, text)` triplet matches one of the
    /// drops. Headers / pause-resume / gap markers / summary blocks are
    /// preserved because `parseTranscriptLine` returns nil for them.
    /// Returns the rewritten body and the count of lines actually dropped.
    nonisolated static func applyRedaction(
        source: String,
        drops: [RedactionLine]
    ) -> (String, Int) {
        struct Key: Hashable { let time: String; let source: String; let text: String }
        var lookup: Set<Key> = []
        for d in drops {
            lookup.insert(Key(time: d.time, source: d.source, text: d.text))
        }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var dropped = 0
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            if let parsed = parseTranscriptLine(line) {
                let key = Key(time: parsed.time, source: parsed.source, text: parsed.text)
                if lookup.contains(key) {
                    dropped += 1
                    continue
                }
            }
            out.append(line)
        }
        return (out.joined(separator: "\n"), dropped)
    }

    /// `yyyy-MM-dd` parser mirroring TranscriptWriter's writer-side
    /// formatter. Used by `timelineForDay` to anchor the requested day
    /// in the same local-time bucket the on-disk file uses.
    nonisolated static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Speaker curation (needs-naming queue + merge suggestions)

    /// One row for the curation window's "needs naming" list. Carries the
    /// data the user needs to recognize the voice (frequency + a few sample
    /// utterances) so they can name them without scrubbing the transcript.
    struct UnnamedCurationRow: Sendable, Identifiable, Equatable {
        let id: Int64
        let displayLabel: String
        /// Total segments attributed to this speaker (all dates, all
        /// sources). Drives the ranking.
        let segmentCount: Int
        /// Mic-context embedding count — useful at a glance when the user
        /// decides whether to merge a thinly-evidenced row.
        let micEmbeddingCount: Int
        let systemEmbeddingCount: Int
        /// Up to N sample utterances, longest+most-recent first. Picked
        /// to aid recognition.
        let sampleQuotes: [SampleQuote]
    }

    struct SampleQuote: Sendable, Identifiable, Equatable {
        let id: Int64
        let text: String
        let startedAt: Date
        let source: Context
    }

    /// Likely-same-person suggestion: a pair of active (non-merged)
    /// speakers whose cross-context cosine similarity falls in the
    /// "just below the auto-merge threshold" band. One-click confirm in
    /// the curation UI runs `mergeSpeakers(source:into:)` using the
    /// recommended direction.
    struct MergeSuggestion: Sendable, Identifiable, Equatable {
        /// "minID-maxID" so SwiftUI ForEach has a stable key per pair.
        let id: String
        let speakerA: Int64
        let speakerALabel: String
        let speakerB: Int64
        let speakerBLabel: String
        let similarity: Double
        /// Merge `recommendedSource` INTO `recommendedDestination`.
        /// Destination preference order: named speaker > more segments >
        /// lower id.
        let recommendedSource: Int64
        let recommendedDestination: Int64
    }

    /// Count of speakers that need naming: unnamed (name IS NULL) +
    /// non-merged + non-owner. Powers the menu bar badge so the UI can
    /// nudge the user toward the curation surface without opening it.
    func unnamedSpeakerCount() throws -> Int {
        let ownerID = AppSettings.ownerSpeakerIDValue
        return try dbQueue.read { db in
            let ownerClause: String
            let args: [DatabaseValueConvertible?]
            if let ownerID {
                ownerClause = "AND id <> ?"
                args = [ownerID]
            } else {
                ownerClause = ""
                args = []
            }
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM speakers
                    WHERE name IS NULL
                      AND merged_into IS NULL
                      \(ownerClause)
                    """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    /// Rows for the "Needs Naming" curation window. Ranked DESC by total
    /// segment count so the most-frequent voices surface first — they are
    /// the ones the user most needs to disambiguate. Excludes the owner
    /// (already named via enrollment), merged rows, and named rows.
    /// Sample quotes are pulled per row: longest texts first (longer
    /// utterances carry more recognition signal), tie-broken by most
    /// recent.
    func unnamedSpeakersForCuration(quotesPerSpeaker: Int = 3) throws -> [UnnamedCurationRow] {
        let ownerID = AppSettings.ownerSpeakerIDValue
        return try dbQueue.read { db in
            let ownerClause: String
            let ownerArgs: [DatabaseValueConvertible?]
            if let ownerID {
                ownerClause = "AND s.id <> ?"
                ownerArgs = [ownerID]
            } else {
                ownerClause = ""
                ownerArgs = []
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.id AS id,
                           COALESCE(s.display_label, 'Speaker ?') AS label,
                           (SELECT COUNT(*) FROM segments seg WHERE seg.speaker_id = s.id) AS segment_count,
                           COALESCE(SUM(CASE WHEN e.context = 'mic' THEN 1 ELSE 0 END), 0) AS mic_count,
                           COALESCE(SUM(CASE WHEN e.context = 'system' THEN 1 ELSE 0 END), 0) AS system_count
                    FROM speakers s
                    LEFT JOIN embeddings e ON e.speaker_id = s.id
                    WHERE s.name IS NULL
                      AND s.merged_into IS NULL
                      \(ownerClause)
                    GROUP BY s.id
                    ORDER BY segment_count DESC, s.id ASC
                    """,
                arguments: StatementArguments(ownerArgs)
            )

            var result: [UnnamedCurationRow] = []
            result.reserveCapacity(rows.count)
            for row in rows {
                let speakerID: Int64 = row["id"]
                let quotes = try Self.fetchSampleQuotes(
                    db: db,
                    speakerID: speakerID,
                    limit: max(0, quotesPerSpeaker)
                )
                result.append(UnnamedCurationRow(
                    id: speakerID,
                    displayLabel: row["label"] ?? "Speaker ?",
                    segmentCount: row["segment_count"] ?? 0,
                    micEmbeddingCount: row["mic_count"] ?? 0,
                    systemEmbeddingCount: row["system_count"] ?? 0,
                    sampleQuotes: quotes
                ))
            }
            return result
        }
    }

    private static func fetchSampleQuotes(
        db: Database,
        speakerID: Int64,
        limit: Int
    ) throws -> [SampleQuote] {
        guard limit > 0 else { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, start_ts, source, text FROM segments
                WHERE speaker_id = ? AND TRIM(text) <> ''
                ORDER BY LENGTH(text) DESC, start_ts DESC
                LIMIT ?
                """,
            arguments: [speakerID, limit]
        )
        return rows.map { row -> SampleQuote in
            let id: Int64 = row["id"]
            let ts: Double = row["start_ts"] ?? 0
            let sourceRaw: String = row["source"] ?? "mic"
            let text: String = row["text"] ?? ""
            return SampleQuote(
                id: id,
                text: text,
                startedAt: Date(timeIntervalSince1970: ts),
                source: Context(rawValue: sourceRaw) ?? .mic
            )
        }
    }

    /// Cross-context cosine candidates that fall in the "just below the
    /// auto-merge threshold" band — the live resolver folds cross-context
    /// matches at >=0.75 automatically, so anything in `[minimum, ceiling)`
    /// is a likely-same-person pair the user should confirm by hand.
    ///
    /// Pairs are computed over all non-merged speakers; the destination
    /// preference is named > more segments > lower id, so a named speaker
    /// always absorbs an unnamed one when the user confirms.
    func mergeSuggestions(
        minimum: Double = 0.60,
        ceiling: Double = 0.75,
        limit: Int = 10
    ) throws -> [MergeSuggestion] {
        guard minimum < ceiling, limit > 0 else { return [] }

        struct ActiveSpeaker {
            let id: Int64
            let label: String
            let name: String?
            let segmentCount: Int
        }

        let (speakers, micVectors, systemVectors) = try dbQueue.read { db -> ([ActiveSpeaker], [Int64: [[Float]]], [Int64: [[Float]]]) in
            let speakerRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.id AS id,
                           s.name AS name,
                           COALESCE(s.display_label, s.name, 'Speaker ?') AS label,
                           (SELECT COUNT(*) FROM segments seg WHERE seg.speaker_id = s.id) AS segment_count
                    FROM speakers s
                    WHERE s.merged_into IS NULL
                    """
            )
            let speakers: [ActiveSpeaker] = speakerRows.map { row in
                ActiveSpeaker(
                    id: row["id"],
                    label: row["label"] ?? "Speaker ?",
                    name: row["name"],
                    segmentCount: row["segment_count"] ?? 0
                )
            }
            let activeIDs = Set(speakers.map(\.id))

            func loadVectors(context: Context) throws -> [Int64: [[Float]]] {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT speaker_id, vector FROM embeddings WHERE context = ?",
                    arguments: [context.rawValue]
                )
                var map: [Int64: [[Float]]] = [:]
                for row in rows {
                    let speakerID: Int64 = row["speaker_id"]
                    guard activeIDs.contains(speakerID) else { continue }
                    guard let blob: Data = row["vector"] else { continue }
                    let count = blob.count / MemoryLayout<Float>.size
                    guard count > 0 else { continue }
                    let vector: [Float] = blob.withUnsafeBytes { raw in
                        let floats = raw.bindMemory(to: Float.self)
                        return Array(floats.prefix(count))
                    }
                    map[speakerID, default: []].append(vector)
                }
                return map
            }

            return (speakers, try loadVectors(context: .mic), try loadVectors(context: .system))
        }

        guard speakers.count >= 2 else { return [] }

        var suggestions: [MergeSuggestion] = []
        for i in 0..<speakers.count {
            let a = speakers[i]
            let aMic = micVectors[a.id] ?? []
            let aSys = systemVectors[a.id] ?? []
            for j in (i + 1)..<speakers.count {
                let b = speakers[j]
                let bMic = micVectors[b.id] ?? []
                let bSys = systemVectors[b.id] ?? []
                // Cross-context only: A.mic vs B.system  AND  A.system vs B.mic.
                let cross1 = Self.maxCosine(aMic, bSys)
                let cross2 = Self.maxCosine(aSys, bMic)
                let score = max(cross1, cross2)
                guard score >= minimum, score < ceiling else { continue }

                let (src, dst) = Self.recommendMergeDirection(
                    a: (id: a.id, name: a.name, segmentCount: a.segmentCount),
                    b: (id: b.id, name: b.name, segmentCount: b.segmentCount)
                )
                let pairKey = "\(min(a.id, b.id))-\(max(a.id, b.id))"
                suggestions.append(MergeSuggestion(
                    id: pairKey,
                    speakerA: a.id,
                    speakerALabel: a.label,
                    speakerB: b.id,
                    speakerBLabel: b.label,
                    similarity: score,
                    recommendedSource: src,
                    recommendedDestination: dst
                ))
            }
        }

        suggestions.sort { $0.similarity > $1.similarity }
        if suggestions.count > limit {
            return Array(suggestions.prefix(limit))
        }
        return suggestions
    }

    /// Destination preference: named > more segments > lower id. The
    /// other speaker becomes the source. Inputs are (id, name?, segmentCount)
    /// tuples so callers can hand in arbitrary speaker carriers.
    static func recommendMergeDirection(
        a: (id: Int64, name: String?, segmentCount: Int),
        b: (id: Int64, name: String?, segmentCount: Int)
    ) -> (source: Int64, destination: Int64) {
        let aNamed = a.name != nil
        let bNamed = b.name != nil
        if aNamed && !bNamed { return (b.id, a.id) }
        if bNamed && !aNamed { return (a.id, b.id) }
        if a.segmentCount != b.segmentCount {
            return a.segmentCount > b.segmentCount ? (b.id, a.id) : (a.id, b.id)
        }
        return a.id <= b.id ? (b.id, a.id) : (a.id, b.id)
    }

    /// Max cosine across two embedding bags. Empty bags return -1 so
    /// they cannot accidentally satisfy a positive threshold.
    private static func maxCosine(_ left: [[Float]], _ right: [[Float]]) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return -1 }
        var best: Double = -1
        for l in left {
            for r in right {
                let s = cosineSimilarity(l, r)
                if s > best { best = s }
            }
        }
        return best
    }

    /// Cosine similarity (same form the IdentityResolver uses). Returns
    /// 0 for length-mismatched or empty inputs.
    nonisolated static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0
        var na: Double = 0
        var nb: Double = 0
        for i in 0..<a.count {
            let ai = Double(a[i])
            let bi = Double(b[i])
            dot += ai * bi
            na += ai * ai
            nb += bi * bi
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    // MARK: - Resolver telemetry (write + read)

    /// One row per IdentityResolver decision. Called from
    /// `IdentityResolver.resolve` on every code path except CACHE-HIT
    /// (no candidate scores to record). Failures are swallowed — the
    /// resolver's live path must never throw out into the merge layer.
    func recordMatchDecision(_ record: MatchDecisionRecord) {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO match_decisions (
                            decided_at, source, session_id, slot_label, outcome,
                            resolved_speaker_id,
                            best_same_speaker_id, best_same_score,
                            best_cross_speaker_id, best_cross_score,
                            same_threshold, cross_threshold,
                            same_candidate_count, cross_candidate_count,
                            ground_truth_speaker_id
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                        """,
                    arguments: [
                        SpeakerLibrary.iso8601Formatter.string(from: record.decidedAt),
                        record.context.rawValue,
                        record.sessionID.uuidString,
                        record.slotLabel,
                        record.outcome.rawValue,
                        record.resolvedSpeakerID,
                        record.bestSameSpeakerID,
                        record.bestSameScore,
                        record.bestCrossSpeakerID,
                        record.bestCrossScore,
                        record.sameThreshold,
                        record.crossThreshold,
                        record.sameCandidateCount,
                        record.crossCandidateCount
                    ]
                )
            }
        } catch {
            log.error("Match-decision write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Retroactive analysis surface. Reads from the `merge_audit` table
    /// populated by `mergeSpeakers` at the moment of each merge — that
    /// is the only correct read because `mergeSpeakers` reassigns the
    /// source's embeddings to the destination, so a post-merge cosine
    /// sweep would find nothing on the source side.
    func historicalMergePairScores() throws -> [HistoricalMergeScore] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT ma.source_speaker_id AS source_id,
                           ma.destination_speaker_id AS dest_id,
                           ma.max_same_context_score AS max_same,
                           ma.max_cross_context_score AS max_cross,
                           COALESCE(d.name, d.display_label, 'Speaker ?') AS dest_label
                    FROM merge_audit ma
                    LEFT JOIN speakers d ON d.id = ma.destination_speaker_id
                    ORDER BY ma.merged_at ASC
                    """
            )
            return rows.map { row -> HistoricalMergeScore in
                HistoricalMergeScore(
                    sourceSpeakerID: row["source_id"],
                    destinationSpeakerID: row["dest_id"],
                    destinationLabel: row["dest_label"] ?? "Speaker ?",
                    maxSameContextScore: row["max_same"],
                    maxCrossContextScore: row["max_cross"]
                )
            }
        }
    }

    /// Compute the max same- and cross-context cosines between two
    /// speakers' embeddings as they currently sit on disk. Called by
    /// `mergeSpeakers` immediately before reassigning embeddings.
    /// Returns nil for either score when one side has no embeddings in
    /// the relevant context bag.
    private func computeMergeAuditScores(
        source: Int64,
        destination: Int64
    ) async throws -> (maxSame: Double?, maxCross: Double?) {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT speaker_id, context, vector FROM embeddings WHERE speaker_id IN (?, ?)",
                arguments: [source, destination]
            )
            var srcMic: [[Float]] = []
            var srcSys: [[Float]] = []
            var dstMic: [[Float]] = []
            var dstSys: [[Float]] = []
            for row in rows {
                let sid: Int64 = row["speaker_id"]
                let ctx: String = row["context"] ?? "mic"
                guard let blob: Data = row["vector"] else { continue }
                let count = blob.count / MemoryLayout<Float>.size
                guard count > 0 else { continue }
                let vector: [Float] = blob.withUnsafeBytes { raw in
                    let floats = raw.bindMemory(to: Float.self)
                    return Array(floats.prefix(count))
                }
                switch (sid == source, ctx) {
                case (true, "mic"): srcMic.append(vector)
                case (true, _): srcSys.append(vector)
                case (false, "mic"): dstMic.append(vector)
                case (false, _): dstSys.append(vector)
                }
            }
            let sameMic = Self.maxCosineOrNil(srcMic, dstMic)
            let sameSys = Self.maxCosineOrNil(srcSys, dstSys)
            let crossA = Self.maxCosineOrNil(srcMic, dstSys)
            let crossB = Self.maxCosineOrNil(srcSys, dstMic)
            return (Self.maxOptional(sameMic, sameSys), Self.maxOptional(crossA, crossB))
        }
    }

    /// Pull every labeled NO-MATCH row from `match_decisions` (rows whose
    /// `ground_truth_speaker_id` has been backfilled by a user merge),
    /// joined with `speakers.name` on the best-candidate columns so the
    /// stats math can ask "was the wrong best-candidate a NAMED speaker?"
    /// — which is the proxy for "lowering the threshold here would have
    /// merged this voice into the wrong NAMED person."
    func labeledMissDecisions() throws -> [LabeledMissRow] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT md.source AS source,
                           md.ground_truth_speaker_id AS gt,
                           md.best_same_speaker_id AS best_same,
                           md.best_same_score AS best_same_score,
                           md.best_cross_speaker_id AS best_cross,
                           md.best_cross_score AS best_cross_score,
                           md.same_threshold AS same_threshold,
                           md.cross_threshold AS cross_threshold,
                           s_same.name AS best_same_name,
                           s_cross.name AS best_cross_name
                    FROM match_decisions md
                    LEFT JOIN speakers s_same ON s_same.id = md.best_same_speaker_id
                    LEFT JOIN speakers s_cross ON s_cross.id = md.best_cross_speaker_id
                    WHERE md.outcome = 'no-match'
                      AND md.ground_truth_speaker_id IS NOT NULL
                    """
            )
            return rows.compactMap { row -> LabeledMissRow? in
                let sourceRaw: String = row["source"] ?? "mic"
                guard let context = Context(rawValue: sourceRaw) else { return nil }
                let gt: Int64 = row["gt"]
                let bestSameID: Int64? = row["best_same"]
                let bestSameScore: Double? = row["best_same_score"]
                let bestCrossID: Int64? = row["best_cross"]
                let bestCrossScore: Double? = row["best_cross_score"]
                let sameThreshold: Double = row["same_threshold"] ?? 0
                let crossThreshold: Double = row["cross_threshold"] ?? 0
                let bestSameName: String? = row["best_same_name"]
                let bestCrossName: String? = row["best_cross_name"]
                let sameScore: Double? = (bestSameID == gt) ? bestSameScore : nil
                let crossScore: Double? = (bestCrossID == gt) ? bestCrossScore : nil
                let bestSameWasNamedNonMatch = (bestSameID != nil)
                    && (bestSameID != gt)
                    && (bestSameName != nil)
                let bestCrossWasNamedNonMatch = (bestCrossID != nil)
                    && (bestCrossID != gt)
                    && (bestCrossName != nil)
                return LabeledMissRow(
                    context: context,
                    groundTruthSpeakerID: gt,
                    sameScore: sameScore,
                    crossScore: crossScore,
                    sameThreshold: sameThreshold,
                    crossThreshold: crossThreshold,
                    bestSameWasNamedNonMatch: bestSameWasNamedNonMatch,
                    bestCrossWasNamedNonMatch: bestCrossWasNamedNonMatch
                )
            }
        }
    }

    /// One-shot aggregate the curation window renders inside its
    /// disclosure section. Combines:
    ///  - Retroactive merge analysis (works on existing data).
    ///  - Live decision telemetry (sharper, only available going forward).
    /// Returns coarse stats — the user does not need raw rows here, just
    /// "is the threshold too strict, and by how much."
    func matchDecisionStats(
        currentSameThreshold: Double = IdentityResolver.defaultSameContextThreshold,
        currentCrossThreshold: Double = IdentityResolver.defaultCrossContextThreshold,
        thresholdSweep: [Double] = [0.50, 0.55, 0.58, 0.60, 0.62, 0.65, 0.68, 0.70, 0.72, 0.75]
    ) throws -> MatchDecisionStats {
        let live = try labeledMissDecisions()
        let historical = try historicalMergePairScores()

        let liveTotal: Int = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM match_decisions") ?? 0
        }
        let liveNoMatchTotal: Int = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM match_decisions WHERE outcome = 'no-match'") ?? 0
        }

        // Combine live + historical scores for the score-distribution
        // histograms. Live rows carry the score against the correct
        // speaker AT decision time (sharper). Historical rows carry the
        // score AS OF NOW (upper bound). Both are inputs to "what would
        // a lower threshold have caught."
        var sameScores: [Double] = []
        var crossScores: [Double] = []
        for row in live {
            if let s = row.sameScore { sameScores.append(s) }
            if let s = row.crossScore { crossScores.append(s) }
        }
        for h in historical {
            if let s = h.maxSameContextScore { sameScores.append(s) }
            if let s = h.maxCrossContextScore { crossScores.append(s) }
        }

        let sameHist = Self.histogram(scores: sameScores)
        let crossHist = Self.histogram(scores: crossScores)

        // Source clustering: only live rows know the source pipeline
        // (historical merges don't carry one). Counted on labeled
        // NO-MATCH rows.
        var micMiss = 0
        var systemMiss = 0
        for row in live {
            if row.context == .mic { micMiss += 1 } else { systemMiss += 1 }
        }

        // Per-speaker clustering: top 10 ground-truth speakers by miss count.
        var perSpeaker: [Int64: (count: Int, scores: [Double])] = [:]
        for row in live {
            var entry = perSpeaker[row.groundTruthSpeakerID] ?? (count: 0, scores: [])
            entry.count += 1
            if let s = row.sameScore { entry.scores.append(s) }
            else if let s = row.crossScore { entry.scores.append(s) }
            perSpeaker[row.groundTruthSpeakerID] = entry
        }
        // Historical merges also surface a ground-truth speaker (the
        // destination of the merge). Each pair counts once.
        for h in historical {
            var entry = perSpeaker[h.destinationSpeakerID] ?? (count: 0, scores: [])
            entry.count += 1
            if let s = h.maxSameContextScore { entry.scores.append(s) }
            else if let s = h.maxCrossContextScore { entry.scores.append(s) }
            perSpeaker[h.destinationSpeakerID] = entry
        }

        let speakerLabels: [Int64: String] = try dbQueue.read { db in
            let ids = Array(perSpeaker.keys)
            guard !ids.isEmpty else { return [:] }
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, COALESCE(name, display_label, 'Speaker ?') AS label
                    FROM speakers
                    WHERE id IN (\(placeholders))
                    """,
                arguments: StatementArguments(ids)
            )
            var map: [Int64: String] = [:]
            for row in rows {
                let id: Int64 = row["id"]
                map[id] = row["label"] ?? "Speaker ?"
            }
            return map
        }

        let topMissed = perSpeaker
            .map { (id, entry) -> MatchDecisionStats.PerSpeakerMissRow in
                MatchDecisionStats.PerSpeakerMissRow(
                    speakerID: id,
                    label: speakerLabels[id] ?? "Speaker ?",
                    missCount: entry.count,
                    medianNearMissScore: Self.median(entry.scores)
                )
            }
            .sorted { lhs, rhs in
                if lhs.missCount != rhs.missCount { return lhs.missCount > rhs.missCount }
                return lhs.speakerID < rhs.speakerID
            }
            .prefix(10)

        // Threshold sweep. True-positives count past misses we'd have
        // caught at the candidate threshold; false-positives count past
        // misses where the wrong best-candidate was a NAMED speaker that
        // we'd have wrongly merged into. Same-context and cross-context
        // are computed independently.
        var sweep: [MatchDecisionStats.ThresholdSweepRow] = []
        sweep.reserveCapacity(thresholdSweep.count)
        for t in thresholdSweep {
            var sameTP = 0, sameFP = 0, crossTP = 0, crossFP = 0
            for row in live {
                if let s = row.sameScore, s >= t { sameTP += 1 }
                if row.bestSameWasNamedNonMatch {
                    // Use the historical row's actual score against the named
                    // non-match; we don't store it separately, so this is a
                    // proxy: the score we DID store (against ground truth) is
                    // a lower bound, so we only count if either score is ≥ t.
                    // The labeled-miss row's `sameScore` (if not nil) carries
                    // the ground-truth score; if nil, ground truth wasn't top,
                    // and the named non-match had a higher score by definition.
                    if row.sameScore == nil { sameFP += 1 }
                    else if let s = row.sameScore, s < t {
                        // ground-truth score < t but the named non-match's
                        // score is unknown vs t. Conservative: count.
                        // This is an upper-bound estimate of FP, intentional
                        // so we err on the side of caution when recommending.
                        sameFP += 1
                    }
                }
                if let s = row.crossScore, s >= t { crossTP += 1 }
                if row.bestCrossWasNamedNonMatch {
                    if row.crossScore == nil { crossFP += 1 }
                    else if let s = row.crossScore, s < t { crossFP += 1 }
                }
            }
            for h in historical {
                if let s = h.maxSameContextScore, s >= t { sameTP += 1 }
                if let s = h.maxCrossContextScore, s >= t { crossTP += 1 }
            }
            sweep.append(MatchDecisionStats.ThresholdSweepRow(
                threshold: t,
                sameContextTruePositives: sameTP,
                sameContextFalsePositives: sameFP,
                crossContextTruePositives: crossTP,
                crossContextFalsePositives: crossFP
            ))
        }

        return MatchDecisionStats(
            currentSameThreshold: currentSameThreshold,
            currentCrossThreshold: currentCrossThreshold,
            liveDecisionTotal: liveTotal,
            liveNoMatchTotal: liveNoMatchTotal,
            liveLabeledMissTotal: live.count,
            historicalMergePairCount: historical.count,
            sameContextHistogram: sameHist,
            crossContextHistogram: crossHist,
            medianSameContextNearMiss: Self.median(sameScores),
            medianCrossContextNearMiss: Self.median(crossScores),
            micMissCount: micMiss,
            systemMissCount: systemMiss,
            topMissedSpeakers: Array(topMissed),
            thresholdSweep: sweep
        )
    }

    // MARK: - Telemetry helpers (nonisolated so tests / aggregation
    //         math can be exercised without hopping the actor)

    /// 20 fixed bins of width 0.05 from 0.0 to 1.0. Scores outside that
    /// range are clamped to the first / last bin. Empty score arrays
    /// return all-zero bins so the UI never has to special-case empty.
    nonisolated static func histogram(scores: [Double]) -> [MatchDecisionStats.HistogramBin] {
        let binWidth = 0.05
        let binCount = 20
        var counts = Array(repeating: 0, count: binCount)
        for s in scores {
            let clamped = max(0.0, min(0.9999, s))
            let idx = min(binCount - 1, Int(clamped / binWidth))
            counts[idx] += 1
        }
        return (0..<binCount).map { i in
            MatchDecisionStats.HistogramBin(
                lowerBound: Double(i) * binWidth,
                upperBound: Double(i + 1) * binWidth,
                count: counts[i]
            )
        }
    }

    nonisolated static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Max cosine across two embedding bags. Returns nil (not -1) when
    /// either side is empty so the analytics code can distinguish "no
    /// evidence" from "evidence but distant."
    nonisolated static func maxCosineOrNil(_ left: [[Float]], _ right: [[Float]]) -> Double? {
        guard !left.isEmpty, !right.isEmpty else { return nil }
        var best: Double = -1
        for l in left {
            for r in right {
                let s = cosineSimilarity(l, r)
                if s > best { best = s }
            }
        }
        return best
    }

    private nonisolated static func maxOptional(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let x?, nil): return x
        case (nil, let y?): return y
        case (let x?, let y?): return max(x, y)
        }
    }

    // MARK: - Test-only setters

    /// Test-only: set a speaker's name + display_label directly via SQL,
    /// without running `renameSpeaker`'s transactional Markdown rewrite.
    /// Used by the curation unit tests so they don't need to stage a
    /// fake transcript folder + writer just to flip `name`.
    func testForceName(speakerID: Int64, name: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE speakers SET name = ?, display_label = ? WHERE id = ?",
                arguments: [name, name, speakerID]
            )
        }
    }

    /// Test-only: mark a speaker as merged into another via SQL, without
    /// running `mergeSpeakers`'s transactional move. Used by the
    /// curation tests so they don't need to stage a fake transcript
    /// folder + writer just to populate `merged_into`.
    func testForceMergedInto(source: Int64, into destination: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE speakers SET merged_into = ? WHERE id = ?",
                arguments: [destination, source]
            )
        }
    }

    // MARK: - S4 errors

    enum SpeakerLibraryError: LocalizedError {
        case invalidName
        case invalidEmbedding
        case cannotMergeIntoSelf

        var errorDescription: String? {
            switch self {
            case .invalidName: return "Name cannot be empty."
            case .invalidEmbedding: return "Voice embedding cannot be empty."
            case .cannotMergeIntoSelf: return "A speaker cannot be merged into itself."
            }
        }
    }

    // MARK: - Helpers

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// `HH:mm:ss` formatter mirroring TranscriptWriter's so a segment
    /// captured at a given instant produces the SAME time string on the
    /// way back out (otherwise the relabel matcher would miss every line).
    nonisolated static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func timestampString(_ date: Date = Date()) -> String {
        iso8601Formatter.string(from: date)
    }
}
