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
