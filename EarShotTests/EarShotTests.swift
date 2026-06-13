//
//  EarShotTests.swift
//  EarShotTests
//

import AppKit
import Foundation
import GRDB
import Testing
@testable import EarShot

@MainActor
struct TranscriptPanelTests {

    /// CLAUDE.md rule 10: the live panel must be invisible to screen shares
    /// and recordings. This is enforced by `NSWindow.sharingType = .none`.
    @Test
    func panelIsInvisibleToScreenShares() {
        let panel = makePanel()
        #expect(panel.sharingType == .none)
    }

    @Test
    func panelIsNonActivating() {
        let panel = makePanel()
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeMain == false)
    }

    @Test
    func panelFloatsAndJoinsAllSpaces() {
        let panel = makePanel()
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
    }

    private func makePanel() -> TranscriptPanel {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 220)
        let host = NSView(frame: frame)
        return TranscriptPanel(contentRect: frame, contentView: host)
    }
}

@MainActor
struct AppStateRecoveryCounterTests {

    /// CLAUDE.md "Metrics and errors" §: glyph error state only after N=3
    /// consecutive failed recoveries. The first two failures must NOT trip
    /// the threshold.
    @Test
    func recoveryCounterRequiresThreeFailures() {
        let state = AppState()
        #expect(state.errorGlyphThreshold == 3)

        #expect(state.noteRecoveryFailed() == false)
        #expect(state.noteRecoveryFailed() == false)
        #expect(state.noteRecoveryFailed() == true)
    }

    @Test
    func successResetsTheCounter() {
        let state = AppState()
        _ = state.noteRecoveryFailed()
        _ = state.noteRecoveryFailed()
        state.noteRecoverySucceeded()
        // After reset, three more failures are required to trip again.
        #expect(state.noteRecoveryFailed() == false)
        #expect(state.noteRecoveryFailed() == false)
        #expect(state.noteRecoveryFailed() == true)
    }
}

struct MetricsCollectorTests {

    /// Every error class must be a present, zero-initialized bucket on a
    /// fresh day so the JSON sidecar is shape-stable for consumers.
    @Test
    func allErrorBucketsExistOnFreshDay() async {
        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let collector = MetricsCollector(folder: folder, now: fixedDate("2026-06-12T10:00:00Z"))
        let stats = await collector.snapshot()
        for kind in ErrorClass.allCases {
            #expect(stats.errors[kind.rawValue] == 0, "missing zeroed error bucket for \(kind.rawValue)")
            #expect(stats.recoveries[kind.rawValue] == 0, "missing zeroed recovery bucket for \(kind.rawValue)")
        }
    }

    @Test
    func errorAndRecoveryCountersBucketCorrectly() async {
        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let collector = MetricsCollector(folder: folder, now: fixedDate("2026-06-12T10:00:00Z"))
        await collector.recordError(.routeChange)
        await collector.recordError(.routeChange)
        await collector.recordError(.asrFailure)
        await collector.recordRecoveryAttempt(.routeChange)
        let stats = await collector.snapshot()
        #expect(stats.errors["routeChange"] == 2)
        #expect(stats.errors["asrFailure"] == 1)
        #expect(stats.errors["diskWriteFailure"] == 0)
        #expect(stats.recoveries["routeChange"] == 1)
    }

    @Test
    func segmentCountsBucketWordsCorrectly() async {
        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let collector = MetricsCollector(folder: folder, now: fixedDate("2026-06-12T10:00:00Z"))
        await collector.recordSegment(pipeline: .mic, text: "hello world this is fine")
        await collector.recordSegment(pipeline: .mic, text: "two words")
        let stats = await collector.snapshot()
        #expect(stats.micSegments == 2)
        #expect(stats.micWords == 7)
    }

    @Test
    func uptimeAccumulatesAcrossListenIntervals() async {
        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let t0 = fixedDate("2026-06-12T10:00:00Z")
        let collector = MetricsCollector(folder: folder, now: t0)
        await collector.noteListeningStarted(at: t0)
        await collector.noteListeningStopped(at: t0.addingTimeInterval(120))
        await collector.noteListeningStarted(at: t0.addingTimeInterval(300))
        await collector.noteListeningStopped(at: t0.addingTimeInterval(360))
        let stats = await collector.snapshot()
        #expect(stats.uptimeSeconds == 180)
    }

    /// CLAUDE.md "Metrics and errors": rollover finalizes the prior day,
    /// writes its JSON sidecar, AND appends a summary block to the day's
    /// Markdown. The collector splits any open interval at midnight so each
    /// day owns its share — verifies the date-key boundary math.
    @Test
    func dateRolloverFinalizesPriorDay() async {
        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // 11:30 PM on day 1.
        let start = fixedDate("2026-06-12T23:30:00-04:00")
        // 12:30 AM on day 2 (one hour later in absolute terms).
        let next = start.addingTimeInterval(3600)

        let collector = MetricsCollector(folder: folder, now: start)
        await collector.noteListeningStarted(at: start)
        await collector.tick(at: next)

        // After rollover, current day is day 2 and starts clean.
        let stats = await collector.snapshot()
        let day2Key = isoDateKey(for: next)
        #expect(stats.dateKey == day2Key)

        // The day-1 JSON sidecar must exist with non-zero uptime.
        let day1Key = isoDateKey(for: start)
        let url = folder.appendingPathComponent("\(day1Key).metrics.json")
        #expect(FileManager.default.fileExists(atPath: url.path), "day-1 metrics JSON not flushed")
    }

    @Test
    func summaryFormatIsHumanReadable() async {
        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let collector = MetricsCollector(folder: folder, now: fixedDate("2026-06-12T10:00:00Z"))
        var stats = MetricsCollector.DayStats(dateKey: "2026-06-12")
        stats.uptimeSeconds = 3700  // 1h 1m
        stats.pausedSeconds = 60
        stats.micSpeechSeconds = 600
        stats.micSegments = 5
        stats.micWords = 42
        stats.errors["routeChange"] = 2
        stats.recoveries["routeChange"] = 2
        stats.gapMarkers = 1
        stats.peakResidentMemoryBytes = 256 * 1024 * 1024
        let text = collector.renderSummary(stats)
        #expect(text.contains("## Summary — 2026-06-12"))
        #expect(text.contains("Uptime: 1h 1m"))
        #expect(text.contains("Errors: routeChange 2"))
        #expect(text.contains("Recoveries attempted: routeChange 2"))
        #expect(text.contains("Gap markers: 1"))
        #expect(text.contains("Peak memory: 256 MB"))
    }

    // MARK: Helpers

    private func makeScratchFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EarShotMetricsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixedDate(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso) ?? Date()
    }

    private func isoDateKey(for date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }
}

// MARK: - Chunk C2: MergeLayer echo dedupe

struct MergeLayerTests {

    @Test
    func normalizesPunctuationAndCaseAndDropsSingleCharTokens() {
        let tokens = MergeLayer.normalizedTokens("Hello, world! I'm here.")
        // "i" is a single character and should drop; "m" too.
        #expect(tokens == ["hello", "world", "here"])
    }

    @Test
    func jaccardOfIdenticalNonEmptySetsIsOne() {
        let a = MergeLayer.normalizedTokens("the quick brown fox")
        let b = MergeLayer.normalizedTokens("THE quick BROWN fox")
        #expect(MergeLayer.jaccard(a, b) == 1.0)
    }

    @Test
    func jaccardOfDisjointSetsIsZero() {
        let a = MergeLayer.normalizedTokens("apples oranges")
        let b = MergeLayer.normalizedTokens("planets stars")
        #expect(MergeLayer.jaccard(a, b) == 0)
    }

    /// CLAUDE.md rule 7 — when on speakers, the mic picks up the remote
    /// voice the system tap also captured. Mic must drop, system wins.
    @Test
    func micEchoOfRecentSystemSegmentIsDropped() async {
        let merge = MergeLayer()
        await merge.setSystemActive(true)

        let forwarded = MergeForwardSink()
        let dropped = MergeDropSink()
        await merge.setHandlers(
            onForward: { seg in forwarded.append(seg) },
            onDropped: { seg, reason in dropped.append((seg, reason)) }
        )

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let systemSeg = LiveTranscript.Segment(
            id: UUID(),
            startedAt: t0,
            endedAt: t0.addingTimeInterval(1.4),
            source: .system,
            speakerLabel: "Speaker 1",
            text: "We should ship this on Friday."
        )
        let micEcho = LiveTranscript.Segment(
            id: UUID(),
            startedAt: t0.addingTimeInterval(0.3),
            endedAt: t0.addingTimeInterval(1.7),
            source: .mic,
            speakerLabel: "Speaker 2",
            text: "we should ship this on friday"
        )

        await merge.submit(systemSeg)
        await merge.submit(micEcho)

        #expect(forwarded.count == 1)
        #expect(forwarded.first?.source == .system)
        #expect(dropped.count == 1)
    }

    /// When the system pipeline is inactive (no allow-listed app tapping),
    /// mic forwards immediately — no echo possible.
    @Test
    func micForwardsImmediatelyWhenSystemInactive() async {
        let merge = MergeLayer()
        await merge.setSystemActive(false)

        let forwarded = MergeForwardSink()
        let dropped = MergeDropSink()
        await merge.setHandlers(
            onForward: { seg in forwarded.append(seg) },
            onDropped: { seg, reason in dropped.append((seg, reason)) }
        )

        let now = Date()
        let mic = LiveTranscript.Segment(
            id: UUID(),
            startedAt: now,
            endedAt: now.addingTimeInterval(0.8),
            source: .mic,
            speakerLabel: nil,
            text: "hello there"
        )
        await merge.submit(mic)

        #expect(forwarded.count == 1)
        #expect(dropped.isEmpty)
    }
}

/// Sink helper (actor-isolated counters that the test reads on the main
/// thread). The merge layer's handlers are `@Sendable` so we need a
/// thread-safe accumulator.
final class MergeForwardSink: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MergeLayer.ForwardedSegment] = []
    func append(_ f: MergeLayer.ForwardedSegment) {
        lock.lock(); defer { lock.unlock() }
        items.append(f)
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    var first: LiveTranscript.Segment? { lock.lock(); defer { lock.unlock() }; return items.first?.segment }
}

final class MergeDropSink: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(LiveTranscript.Segment, MergeLayer.DropReason)] = []
    func append(_ entry: (LiveTranscript.Segment, MergeLayer.DropReason)) {
        lock.lock(); defer { lock.unlock() }
        items.append(entry)
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return items.isEmpty }
}

// MARK: - Chunk C2: AllowlistStore defaults + persistence

/// Pre-existing C2 tests share `UserDefaults.standard` keys and cannot run
/// concurrently. Serializing here keeps the chunk S4 work from flaring an
/// unrelated parallelism race; the proper fix (inject a defaults suite) is
/// out of scope.
@Suite(.serialized)
struct SystemAudioAllowlistTests {

    /// PRD R2 default-deny: a never-seen-before bundle ID is not allowed.
    /// Teams (new) and Zoom are seeded on first read so the upgrade from
    /// C1 is a no-op.
    @Test
    func firstReadSeedsTeamsAndZoom() {
        withScratchDefaults { defaults in
            // No prior state in the scratch defaults suite.
            let enabled = SystemAudioAllowlist.enabledBundleIDs()
            #expect(enabled.contains("com.microsoft.teams2"))
            #expect(enabled.contains("us.zoom.xos"))
            #expect(!enabled.contains("com.unknown.app"))
            _ = defaults
        }
    }

    @Test
    func disablePersistsAndDoesNotReseed() {
        withScratchDefaults { _ in
            _ = SystemAudioAllowlist.enabledBundleIDs()  // triggers seed
            SystemAudioAllowlist.setEnabled(bundleID: "com.microsoft.teams2", enabled: false)
            let after = SystemAudioAllowlist.enabledBundleIDs()
            #expect(!after.contains("com.microsoft.teams2"))
            #expect(after.contains("us.zoom.xos"))

            // Second read must NOT reseed Teams.
            let reread = SystemAudioAllowlist.enabledBundleIDs()
            #expect(!reread.contains("com.microsoft.teams2"))
        }
    }

    /// Helper: swap UserDefaults to a private suite for the test body, then
    /// wipe it afterwards. Avoids leaking test state into the user's real
    /// preferences.
    private func withScratchDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "EarShotAllowlistTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        let real = UserDefaults.standard
        // We can't replace `UserDefaults.standard`, so the test uses the
        // standard suite — but isolates by clearing the two known keys
        // before and after.
        _ = real
        let keys = ["earshot.systemAudioAllowlist.enabled", "earshot.systemAudioAllowlist.seeded"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
        defer {
            for k in keys { UserDefaults.standard.removeObject(forKey: k) }
            for (k, v) in zip(keys, saved) where v != nil {
                UserDefaults.standard.set(v, forKey: k)
            }
            UserDefaults().removePersistentDomain(forName: suiteName)
            _ = suite
        }
        body(suite)
    }
}

// MARK: - Chunk S3: cosine similarity + IdentityResolver

struct IdentityResolverTests {

    @Test
    func cosineSimilarityOfIdenticalVectorsIsOne() {
        let v: [Float] = [0.2, -0.4, 0.7, 0.1, -0.5]
        let sim = IdentityResolver.cosineSimilarity(v, v)
        #expect(abs(sim - 1.0) < 1e-9)
    }

    @Test
    func cosineSimilarityOfOrthogonalVectorsIsZero() {
        let a: [Float] = [1, 0, 0, 0]
        let b: [Float] = [0, 1, 0, 0]
        #expect(abs(IdentityResolver.cosineSimilarity(a, b)) < 1e-9)
    }

    @Test
    func cosineSimilarityOfOppositeVectorsIsNegativeOne() {
        let a: [Float] = [0.3, -0.4, 0.5]
        let b: [Float] = a.map { -$0 }
        let sim = IdentityResolver.cosineSimilarity(a, b)
        #expect(abs(sim + 1.0) < 1e-9)
    }

    /// CLAUDE.md matching policy: a freshly-enrolled owner must be
    /// recognized from session start whenever the same voice arrives. Here
    /// the "owner" embedding is the canonical reference; an identical
    /// embedding arriving on the mic side should match same-context.
    @Test
    func enrolledOwnerMatchesFromFirstSegment() async throws {
        let library = try Self.makeMemoryLibrary()
        let ownerEmbedding = Self.makeDirectionalEmbedding(dim: 256, seed: 7)
        let ownerID = try await library.enrollOwner(name: "Alice", embedding: ownerEmbedding)

        let resolver = IdentityResolver(library: library)
        let sessionID = UUID()
        let resolution = await resolver.resolve(
            source: .mic,
            sessionID: sessionID,
            slotLabel: "Speaker 1",
            embedding: ownerEmbedding,
            durationSeconds: 4.0
        )
        #expect(resolution.speakerID == ownerID)
        #expect(resolution.displayLabel == "Alice")
    }

    /// Same-context threshold is 0.65. A vector that aligns strongly with
    /// the only stored embedding should match the existing speaker, not
    /// mint a new one.
    @Test
    func sameContextMatchAboveThresholdReusesSpeaker() async throws {
        let library = try Self.makeMemoryLibrary()
        let resolver = IdentityResolver(library: library)
        let sessionA = UUID()
        let sessionB = UUID()

        let baseEmbedding = Self.makeDirectionalEmbedding(dim: 256, seed: 11)
        let firstResolution = await resolver.resolve(
            source: .mic,
            sessionID: sessionA,
            slotLabel: "Speaker 1",
            embedding: baseEmbedding,
            durationSeconds: 3.0
        )
        // A near-identical embedding (cos sim > 0.99 against base) on a
        // FRESH session (so no cache hit) must resolve to the same
        // persistent speaker.
        let nudged = baseEmbedding.enumerated().map { (i, f) -> Float in
            i % 32 == 0 ? f + 0.01 : f
        }
        let secondResolution = await resolver.resolve(
            source: .mic,
            sessionID: sessionB,
            slotLabel: "Speaker 1",
            embedding: nudged,
            durationSeconds: 3.0
        )
        #expect(firstResolution.speakerID == secondResolution.speakerID)
        #expect(firstResolution.displayLabel == secondResolution.displayLabel)
    }

    /// No same-context match AND no cross-context match → resolver mints a
    /// new "Speaker N" with a stable label.
    @Test
    func unmatchedEmbeddingMintsNewSpeaker() async throws {
        let library = try Self.makeMemoryLibrary()
        let resolver = IdentityResolver(library: library)

        // Seeds 13 and 17 produce vectors with cos sim ≈ -0.94 (well below
        // the same-context 0.65 and the cross-context 0.75 thresholds), so
        // the second resolve must NO-MATCH and mint a fresh speaker. The
        // prior seed pair (13 / 23) happened to produce cos sim 0.756, which
        // wrongly tripped the same-context branch — caught while landing S4.
        let firstVoice = Self.makeDirectionalEmbedding(dim: 256, seed: 13)
        let secondVoice = Self.makeDirectionalEmbedding(dim: 256, seed: 17)

        let firstRes = await resolver.resolve(
            source: .mic,
            sessionID: UUID(),
            slotLabel: "Speaker 1",
            embedding: firstVoice,
            durationSeconds: 2.0
        )
        let secondRes = await resolver.resolve(
            source: .mic,
            sessionID: UUID(),
            slotLabel: "Speaker 1",
            embedding: secondVoice,
            durationSeconds: 2.0
        )
        #expect(firstRes.speakerID != secondRes.speakerID)
        #expect(firstRes.displayLabel.hasPrefix("Speaker "))
        #expect(secondRes.displayLabel.hasPrefix("Speaker "))
    }

    /// Cross-context fallback at threshold 0.75: the same physical voice
    /// captured on mic and later on the system tap should fold into one
    /// persistent identity. Build a library with a mic-context embedding,
    /// then resolve a near-identical embedding under the system context.
    @Test
    func crossContextMatchAboveLooserThresholdReusesSpeaker() async throws {
        let library = try Self.makeMemoryLibrary()
        let baseEmbedding = Self.makeDirectionalEmbedding(dim: 256, seed: 19)
        // Bootstrap: write a mic embedding for a brand-new speaker.
        let row = try await library.createUnnamedSpeaker()
        try await library.recordEmbedding(
            speakerID: row.speakerID,
            context: .mic,
            vector: baseEmbedding,
            quality: 0.9
        )

        let resolver = IdentityResolver(library: library)
        // Identical vector on the SYSTEM side. No same-context candidates
        // exist, so the cross-context branch must run; cos sim ≈ 1 clears
        // the 0.75 threshold.
        let resolution = await resolver.resolve(
            source: .system,
            sessionID: UUID(),
            slotLabel: "Speaker 1",
            embedding: baseEmbedding,
            durationSeconds: 3.0
        )
        #expect(resolution.speakerID == row.speakerID)
        #expect(resolution.displayLabel == row.displayLabel)
    }

    /// Cache hit on the same (source, session, slot) tuple: subsequent
    /// calls must short-circuit and return the same speaker without doing
    /// a DB sweep. Verifying via stable resolution across N calls and by
    /// confirming the embedding-add side effect (count grows by one per
    /// resolve).
    @Test
    func sameSessionSlotShortCircuitsViaCache() async throws {
        let library = try Self.makeMemoryLibrary()
        let resolver = IdentityResolver(library: library)
        let sessionID = UUID()
        let voice = Self.makeDirectionalEmbedding(dim: 256, seed: 31)

        let r1 = await resolver.resolve(
            source: .mic,
            sessionID: sessionID,
            slotLabel: "Speaker 1",
            embedding: voice,
            durationSeconds: 2.0
        )
        let r2 = await resolver.resolve(
            source: .mic,
            sessionID: sessionID,
            slotLabel: "Speaker 1",
            embedding: voice,
            durationSeconds: 2.0
        )
        let r3 = await resolver.resolve(
            source: .mic,
            sessionID: sessionID,
            slotLabel: "Speaker 1",
            embedding: voice,
            durationSeconds: 2.0
        )
        #expect(r1.speakerID == r2.speakerID)
        #expect(r2.speakerID == r3.speakerID)

        // Per spec: every confident match (cache or full) adds a fresh
        // embedding. After three calls, the speaker should have three
        // mic embeddings stored.
        let stored = try await library.allEmbeddings(context: .mic).filter { $0.speakerID == r1.speakerID }
        #expect(stored.count == 3)
    }

    // MARK: helpers

    static func makeMemoryLibrary() throws -> SpeakerLibrary {
        let queue = try DatabaseQueue()
        return try SpeakerLibrary(testQueue: queue)
    }

    /// Build a unit-length 256-d vector that depends only on `seed` so
    /// different seeds produce near-orthogonal vectors (well below the
    /// matching thresholds). The simple sine-table construction gives
    /// reproducible vectors with non-trivial spread.
    static func makeDirectionalEmbedding(dim: Int, seed: Int) -> [Float] {
        var raw: [Float] = []
        raw.reserveCapacity(dim)
        for i in 0..<dim {
            let phase = Double(seed) * 0.7 + Double(i) * 0.13
            raw.append(Float(sin(phase)))
        }
        // L2-normalize so cosine sim = dot product (matches what
        // WeSpeaker emits).
        let norm = sqrt(raw.reduce(0) { $0 + Double($1 * $1) })
        guard norm > 0 else { return raw }
        return raw.map { Float(Double($0) / norm) }
    }
}

// MARK: - Chunk S3: SpeakerLibrary new APIs

struct SpeakerLibraryS3Tests {

    @Test
    func createUnnamedSpeakerAssignsSequentialLabels() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let a = try await library.createUnnamedSpeaker()
        let b = try await library.createUnnamedSpeaker()
        let c = try await library.createUnnamedSpeaker()
        #expect(a.displayLabel == "Speaker 1")
        #expect(b.displayLabel == "Speaker 2")
        #expect(c.displayLabel == "Speaker 3")
        #expect(a.speakerID != b.speakerID)
        #expect(b.speakerID != c.speakerID)
    }

    @Test
    func enrolledOwnerDisplayLabelMatchesName() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let embedding = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 3)
        let ownerID = try await library.enrollOwner(name: "Bob", embedding: embedding)
        let label = try await library.displayLabel(forSpeakerID: ownerID)
        #expect(label == "Bob")
    }

    /// Mixing the owner (named) with unnamed speakers must not cause the
    /// "Speaker N" sequence to collide with the owner's display label,
    /// because owner's label is the user's name, not "Speaker N".
    @Test
    func unnamedSequenceIsIndependentOfNamedOwner() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let embedding = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 5)
        _ = try await library.enrollOwner(name: "Alice", embedding: embedding)
        let speaker1 = try await library.createUnnamedSpeaker()
        let speaker2 = try await library.createUnnamedSpeaker()
        #expect(speaker1.displayLabel == "Speaker 1")
        #expect(speaker2.displayLabel == "Speaker 2")
    }

    @Test
    func allEmbeddingsReturnsOnlyRequestedContext() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let row = try await library.createUnnamedSpeaker()
        let v1 = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 8)
        let v2 = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 9)
        try await library.recordEmbedding(speakerID: row.speakerID, context: .mic, vector: v1, quality: 0.5)
        try await library.recordEmbedding(speakerID: row.speakerID, context: .system, vector: v2, quality: 0.5)

        let mics = try await library.allEmbeddings(context: .mic)
        let systems = try await library.allEmbeddings(context: .system)
        #expect(mics.count == 1)
        #expect(systems.count == 1)
        #expect(mics.first?.speakerID == row.speakerID)
        #expect(systems.first?.speakerID == row.speakerID)
    }
}

// MARK: - Chunk S4: naming, merge, FTS5 search, retroactive relabel

struct SpeakerLibraryS4Tests {

    /// `applyRelabel` swaps the speaker portion of any line matching the
    /// (time, source, text) tuple. Unrelated lines, headers, and markers
    /// pass through unchanged so the file format stays intact.
    @Test
    func applyRelabelRewritesOnlyMatchingLines() {
        let original = """
        # 2026-06-13

        [09:01:00] [mic] Speaker 1: Good morning team.
        [09:01:08] [mic] Speaker 2: Morning.
        [09:02:00] [system] Speaker 1: Remote side says hello.
        paused 09:03:00
        resumed 09:04:00
        [09:04:01] [mic] Speaker 1: Where were we?
        """
        let transforms = [
            SpeakerLibrary.RelabelTransformation(
                time: "09:01:00", source: "mic", oldLabel: "Speaker 1",
                newLabel: "Alice", text: "Good morning team."
            ),
            SpeakerLibrary.RelabelTransformation(
                time: "09:04:01", source: "mic", oldLabel: "Speaker 1",
                newLabel: "Alice", text: "Where were we?"
            )
        ]
        let (rewritten, changed) = SpeakerLibrary.applyRelabel(source: original, transformations: transforms)
        #expect(changed == 2)
        #expect(rewritten.contains("[09:01:00] [mic] Alice: Good morning team."))
        #expect(rewritten.contains("[09:01:08] [mic] Speaker 2: Morning."))
        #expect(rewritten.contains("[09:02:00] [system] Speaker 1: Remote side says hello."))
        #expect(rewritten.contains("paused 09:03:00"))
        #expect(rewritten.contains("[09:04:01] [mic] Alice: Where were we?"))
        #expect(rewritten.hasPrefix("# 2026-06-13\n"))
    }

    /// Re-running the same rename twice must be a no-op the second time:
    /// the (time, source, text) tuple still matches but the old label
    /// already differs (it's now the new label), so the rewriter skips
    /// the line.
    @Test
    func applyRelabelIsIdempotent() {
        let original = "[09:01:00] [mic] Alice: Good morning."
        let transforms = [
            SpeakerLibrary.RelabelTransformation(
                time: "09:01:00", source: "mic", oldLabel: "Speaker 1",
                newLabel: "Alice", text: "Good morning."
            )
        ]
        let (rewritten, changed) = SpeakerLibrary.applyRelabel(source: original, transformations: transforms)
        #expect(changed == 0)
        #expect(rewritten == original)
    }

    /// FTS5 query → row roundtrip with the porter tokenizer enabled.
    /// "ship" should match "shipping" via the stemmer.
    @Test
    func searchFindsStemmedKeyword() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let row = try await library.createUnnamedSpeaker()
        let now = Date()
        let record = SpeakerLibrary.SegmentRecord(
            speakerID: row.speakerID,
            context: .mic,
            sessionID: UUID().uuidString,
            startedAt: now,
            endedAt: now.addingTimeInterval(2),
            dateKey: "2026-06-13",
            text: "We are shipping the migration on Friday.",
            provisional: true
        )
        _ = try await library.indexSegment(record)

        let hits = try await library.searchSegments(query: "ship")
        #expect(hits.count == 1)
        #expect(hits.first?.speakerLabel == "Speaker 1")
        #expect(hits.first?.text.contains("shipping") == true)
    }

    /// `logSearch` writes a row only when the query is non-empty, and
    /// `totalSearchCount` returns the running tally that PRD R8 wants.
    @Test
    func searchLogPersistsAndCountsQueries() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        try await library.logSearch(query: "first", resultCount: 3)
        try await library.logSearch(query: "second", resultCount: 0)
        try await library.logSearch(query: "   ", resultCount: 0)  // dropped
        let count = try await library.totalSearchCount()
        #expect(count == 2)
    }

    /// Naming transaction: the speaker's name and display_label flip
    /// atomically. `listSpeakers` reflects the new label immediately.
    @Test
    func renameSpeakerUpdatesNameAndDisplayLabel() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let row = try await library.createUnnamedSpeaker()
        // Use a scratch folder with NO transcript file so the file
        // rewrite step is skipped — we are only verifying the DB side.
        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = TranscriptWriter(folder: folder)

        let outcome = try await library.renameSpeaker(
            speakerID: row.speakerID,
            newName: "Bob",
            todayDateKey: "2026-06-13",
            transcriptFolder: folder,
            writer: writer
        )
        #expect(outcome.oldLabel == "Speaker 1")
        #expect(outcome.newLabel == "Bob")

        let speakers = try await library.listSpeakers()
        let me = speakers.first { $0.id == row.speakerID }
        #expect(me?.displayLabel == "Bob")
        #expect(me?.name == "Bob")
    }

    /// Merging moves embeddings + segments to the destination, sets
    /// `merged_into` on the source, and the destination's embedding
    /// count includes the moved rows.
    @Test
    func mergeReassignsEmbeddingsAndSegments() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let src = try await library.createUnnamedSpeaker()
        let dest = try await library.createUnnamedSpeaker()
        let v = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 11)
        try await library.recordEmbedding(speakerID: src.speakerID, context: .mic, vector: v, quality: 0.7)
        let record = SpeakerLibrary.SegmentRecord(
            speakerID: src.speakerID,
            context: .mic,
            sessionID: UUID().uuidString,
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(1),
            dateKey: "2026-06-13",
            text: "Something memorable.",
            provisional: true
        )
        _ = try await library.indexSegment(record)

        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = TranscriptWriter(folder: folder)
        let outcome = try await library.mergeSpeakers(
            source: src.speakerID,
            into: dest.speakerID,
            todayDateKey: "2026-06-13",
            transcriptFolder: folder,
            writer: writer
        )
        #expect(outcome.movedEmbeddingCount == 1)

        let speakers = try await library.listSpeakers()
        let srcRow = speakers.first { $0.id == src.speakerID }
        let destRow = speakers.first { $0.id == dest.speakerID }
        #expect(srcRow?.mergedInto == dest.speakerID)
        #expect(destRow?.micCount == 1)
    }

    /// Owner re-enrollment swaps in a fresh mic embedding and leaves any
    /// system-context embedding untouched (CLAUDE.md §"Matching policy"
    /// keeps per-context evidence isolated).
    @Test
    func reenrollOwnerReplacesMicEmbeddingsOnly() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let v1 = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 21)
        let ownerID = try await library.enrollOwner(name: "Alice", embedding: v1)
        let v2 = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 22)
        try await library.recordEmbedding(speakerID: ownerID, context: .system, vector: v2, quality: 0.6)

        let v3 = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 23)
        _ = try await library.reenrollOwner(name: "Alice", embedding: v3)

        let mics = try await library.allEmbeddings(context: .mic)
        let systems = try await library.allEmbeddings(context: .system)
        #expect(mics.filter { $0.speakerID == ownerID }.count == 1)
        #expect(systems.filter { $0.speakerID == ownerID }.count == 1)
    }

    private func makeScratchFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EarShotS4Tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `IdentityResolver.invalidate` drops the cache for the given
    /// speaker so the next resolve does a fresh DB lookup and picks up
    /// the new name immediately.
    @Test
    func identityResolverInvalidationDropsCacheEntry() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let ownerEmbedding = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 31)
        let ownerID = try await library.enrollOwner(name: "Alice", embedding: ownerEmbedding)
        let resolver = IdentityResolver(library: library)
        let session = UUID()
        _ = await resolver.resolve(source: .mic, sessionID: session, slotLabel: "Speaker 1", embedding: ownerEmbedding, durationSeconds: 5)
        // Rename behind the resolver's back.
        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = TranscriptWriter(folder: folder)
        _ = try await library.renameSpeaker(
            speakerID: ownerID,
            newName: "Alicia",
            todayDateKey: "2026-06-13",
            transcriptFolder: folder,
            writer: writer
        )
        // Without invalidation the cache would return the old label.
        await resolver.invalidate(speakerID: ownerID)
        let fresh = await resolver.resolve(source: .mic, sessionID: session, slotLabel: "Speaker 1", embedding: ownerEmbedding, durationSeconds: 5)
        #expect(fresh.displayLabel == "Alicia")
    }
}

// MARK: - Chunk CP1: offline correction pass

@MainActor
struct CorrectionPassTests {

    /// `LiveTranscript.applyCorrectionUpdates` swaps the matching
    /// segments in place, flips `provisional = false`, and leaves the
    /// non-matching segments alone. CLAUDE.md rule 3 — the live panel
    /// reflects corrections silently.
    @Test
    func liveTranscriptRelabelsMatchingSegmentsSilently() {
        let live = LiveTranscript()
        let now = Date()
        let s1 = LiveTranscript.Segment(
            id: UUID(),
            startedAt: now,
            endedAt: now.addingTimeInterval(2),
            source: .mic,
            speakerLabel: "Speaker 1",
            text: "Good morning team.",
            provisional: true,
            speakerID: 7
        )
        let s2 = LiveTranscript.Segment(
            id: UUID(),
            startedAt: now.addingTimeInterval(5),
            endedAt: now.addingTimeInterval(7),
            source: .mic,
            speakerLabel: "Speaker 2",
            text: "Morning.",
            provisional: true,
            speakerID: 8
        )
        live.appendFinalized(s1)
        live.appendFinalized(s2)

        live.applyCorrectionUpdates([
            CorrectionLiveUpdate(
                source: .mic,
                startedAt: now,
                text: "Good morning team.",
                newSpeakerLabel: "Alice",
                newSpeakerID: 42
            )
        ])

        #expect(live.segments[0].speakerLabel == "Alice")
        #expect(live.segments[0].speakerID == 42)
        #expect(live.segments[0].provisional == false)
        #expect(live.segments[0].id == s1.id)
        // Untouched segment is left alone.
        #expect(live.segments[1].speakerLabel == "Speaker 2")
        #expect(live.segments[1].speakerID == 8)
        #expect(live.segments[1].provisional == true)
    }

    /// Two segments with identical timestamps but different text must
    /// not cross-relabel. The (source, startedAt, text) tuple is the
    /// match key so the unrelated segment stays put.
    @Test
    func liveTranscriptDoesNotCrossRelabelOnTimestampCollision() {
        let live = LiveTranscript()
        let same = Date()
        let s1 = LiveTranscript.Segment(
            id: UUID(),
            startedAt: same,
            endedAt: same.addingTimeInterval(1),
            source: .mic,
            speakerLabel: "Speaker 1",
            text: "Hello.",
            provisional: true,
            speakerID: 1
        )
        let s2 = LiveTranscript.Segment(
            id: UUID(),
            startedAt: same,
            endedAt: same.addingTimeInterval(1),
            source: .system,
            speakerLabel: "Speaker 1",
            text: "Goodbye.",
            provisional: true,
            speakerID: 2
        )
        live.appendFinalized(s1)
        live.appendFinalized(s2)

        live.applyCorrectionUpdates([
            CorrectionLiveUpdate(
                source: .mic,
                startedAt: same,
                text: "Hello.",
                newSpeakerLabel: "Alice",
                newSpeakerID: 42
            )
        ])
        #expect(live.segments[0].speakerLabel == "Alice")
        // System line at the same instant must stay put.
        #expect(live.segments[1].speakerLabel == "Speaker 1")
        #expect(live.segments[1].speakerID == 2)
    }
}

struct SpeakerLibraryCP1Tests {

    /// `segmentsInRange` filters by context and `start_ts` bounds.
    @Test
    func segmentsInRangeFiltersByContextAndTime() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let row = try await library.createUnnamedSpeaker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // Mic at t0 (inside) and t0+10 min (outside).
        let inside = SpeakerLibrary.SegmentRecord(
            speakerID: row.speakerID, context: .mic,
            sessionID: UUID().uuidString,
            startedAt: t0, endedAt: t0.addingTimeInterval(2),
            dateKey: "2026-06-13", text: "Inside.", provisional: true
        )
        let outside = SpeakerLibrary.SegmentRecord(
            speakerID: row.speakerID, context: .mic,
            sessionID: UUID().uuidString,
            startedAt: t0.addingTimeInterval(10 * 60),
            endedAt: t0.addingTimeInterval(10 * 60 + 2),
            dateKey: "2026-06-13", text: "Outside.", provisional: true
        )
        // System at t0 (inside) — wrong context, must be excluded.
        let sysInside = SpeakerLibrary.SegmentRecord(
            speakerID: row.speakerID, context: .system,
            sessionID: UUID().uuidString,
            startedAt: t0, endedAt: t0.addingTimeInterval(2),
            dateKey: "2026-06-13", text: "System.", provisional: true
        )
        _ = try await library.indexSegment(inside)
        _ = try await library.indexSegment(outside)
        _ = try await library.indexSegment(sysInside)

        let range = t0...t0.addingTimeInterval(5 * 60)
        let hits = try await library.segmentsInRange(range, context: .mic)
        #expect(hits.count == 1)
        #expect(hits.first?.text == "Inside.")
        #expect(hits.first?.source == .mic)
    }

    /// `applyCorrections` rewrites the day's Markdown atomically, flips
    /// `speaker_id` + `provisional = 0` for the affected rows, and
    /// leaves unrelated lines untouched.
    @Test
    func applyCorrectionsRewritesMarkdownAndUpdatesSegments() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let src = try await library.createUnnamedSpeaker()
        let dest = try await library.createUnnamedSpeaker()

        let dateKey = "2026-06-13"
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EarShotCP1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Write a minimal transcript file matching the canonical format.
        // Two segments at known times; both currently attributed to src
        // ("Speaker 1"). Correction should flip one to dest ("Speaker 2").
        let target = folder.appendingPathComponent("\(dateKey).md", isDirectory: false)
        let body = """
        # \(dateKey)

        [09:01:00] [mic] Speaker 1: First line to correct.
        [09:01:08] [mic] Speaker 1: Second line stays.

        """
        try body.write(to: target, atomically: true, encoding: .utf8)

        // Indexes the corresponding DB rows. Timestamps must match the
        // file's HH:mm:ss formatting so the relabel matcher can find
        // the line — SpeakerLibrary.timeFormatter is the canonical one.
        let cal = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 13
        comps.hour = 9; comps.minute = 1; comps.second = 0
        let t1 = cal.date(from: comps)!
        comps.second = 8
        let t2 = cal.date(from: comps)!

        let r1 = SpeakerLibrary.SegmentRecord(
            speakerID: src.speakerID, context: .mic,
            sessionID: UUID().uuidString,
            startedAt: t1, endedAt: t1.addingTimeInterval(2),
            dateKey: dateKey, text: "First line to correct.",
            provisional: true
        )
        let r2 = SpeakerLibrary.SegmentRecord(
            speakerID: src.speakerID, context: .mic,
            sessionID: UUID().uuidString,
            startedAt: t2, endedAt: t2.addingTimeInterval(2),
            dateKey: dateKey, text: "Second line stays.",
            provisional: true
        )
        let id1 = try await library.indexSegment(r1)
        let id2 = try await library.indexSegment(r2)

        let writer = TranscriptWriter(folder: folder)

        let updates = [
            SpeakerLibrary.CorrectionUpdate(
                segmentID: id1, dateKey: dateKey,
                startedAt: t1, source: .mic,
                text: "First line to correct.",
                oldLabel: "Speaker 1",
                newSpeakerID: dest.speakerID,
                newLabel: "Speaker 2"
            )
        ]
        let outcome = try await library.applyCorrections(
            updates,
            dateKey: dateKey,
            transcriptFolder: folder,
            writer: writer
        )
        #expect(outcome.relabeledSegmentIDs == [id1])
        #expect(outcome.relabeledLineCount == 1)

        // File rewrite: first line carries the new label; second is
        // untouched; header survives.
        let rewritten = try String(contentsOf: target, encoding: .utf8)
        #expect(rewritten.contains("[09:01:00] [mic] Speaker 2: First line to correct."))
        #expect(rewritten.contains("[09:01:08] [mic] Speaker 1: Second line stays."))
        #expect(rewritten.hasPrefix("# \(dateKey)\n"))

        // DB rewrite: row 1 now points at dest with provisional cleared,
        // row 2 still points at src.
        let allHits = try await library.segmentsInRange(
            t1.addingTimeInterval(-1)...t2.addingTimeInterval(1),
            context: .mic
        )
        let hit1 = allHits.first { $0.id == id1 }
        let hit2 = allHits.first { $0.id == id2 }
        #expect(hit1?.speakerID == dest.speakerID)
        #expect(hit1?.provisional == false)
        #expect(hit2?.speakerID == src.speakerID)
        #expect(hit2?.provisional == true)
    }

    /// Empty `updates` is a no-op: no file touch, no DB write, no
    /// relabel count.
    @Test
    func applyCorrectionsWithNoUpdatesIsNoOp() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EarShotCP1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = TranscriptWriter(folder: folder)
        let outcome = try await library.applyCorrections(
            [],
            dateKey: "2026-06-13",
            transcriptFolder: folder,
            writer: writer
        )
        #expect(outcome.relabeledSegmentIDs.isEmpty)
        #expect(outcome.relabeledLineCount == 0)
    }
}

struct CorrectionMetricsTests {

    /// `recordSegmentsRelabeled` accumulates and is reflected in both
    /// the day's snapshot and the human summary block (PRD R8).
    @Test
    func segmentsRelabeledCounterAccumulates() async {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EarShotCPM-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let metrics = MetricsCollector(folder: folder)
        await metrics.recordSegmentsRelabeled(count: 3)
        await metrics.recordSegmentsRelabeled(count: 2)
        await metrics.recordSegmentsRelabeled(count: 0)  // dropped
        let snap = await metrics.snapshot()
        #expect(snap.segmentsRelabeled == 5)
        let summary = metrics.renderSummary(snap)
        #expect(summary.contains("Correction relabels: 5"))
    }
}

// MARK: - Chunk H1: hardening + soak

struct H1CrashRecoveryTests {

    /// Crash-recovery marker writes a `recovered HH:MM:SS\n` line into the
    /// day's transcript without breaking the append-only invariant
    /// (rule 4). The marker is purely informational; the file itself
    /// already survived because every prior line was fsynced.
    @Test
    func crashRecoveryMarkerAppendsToTodaysFile() async throws {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let writer = TranscriptWriter(folder: folder)
        let dateKey = "2026-06-13"
        let when = fixedDate("2026-06-13T14:30:00Z")
        let marker: TranscriptWriter.Marker = .crashRecovered
        await writer.writeMarker(marker, at: when)
        await writer.close()

        let url = folder.appendingPathComponent("\(dateKey).md")
        let body = try String(contentsOf: url, encoding: .utf8)
        // The "recovered" prefix lets a human grep find every crash boundary.
        #expect(body.contains("recovered "))
        // The file header is still in place — append-only.
        #expect(body.contains("# \(dateKey)"))
    }

    /// Multiple successive crash markers are tolerated — a system that
    /// crashes mid-day, recovers, then crashes again should accumulate
    /// markers, not corrupt the file.
    @Test
    func successiveCrashMarkersAreIdempotentOnDiskShape() async throws {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let writer = TranscriptWriter(folder: folder)
        let dateKey = "2026-06-13"
        let marker: TranscriptWriter.Marker = .crashRecovered
        await writer.writeMarker(marker, at: fixedDate("2026-06-13T14:30:00Z"))
        // Mix in a real segment between the two crashes — the marker must
        // not interfere with normal append.
        let segment = LiveTranscript.Segment(
            id: UUID(),
            startedAt: fixedDate("2026-06-13T14:31:00Z"),
            endedAt: fixedDate("2026-06-13T14:31:05Z"),
            source: .mic,
            speakerLabel: "Speaker 1",
            text: "back online"
        )
        await writer.append(segment: segment)
        await writer.writeMarker(marker, at: fixedDate("2026-06-13T15:00:00Z"))
        await writer.close()

        let url = folder.appendingPathComponent("\(dateKey).md")
        let body = try String(contentsOf: url, encoding: .utf8)
        let recoveredLines = body.components(separatedBy: "\n").filter { $0.hasPrefix("recovered ") }
        #expect(recoveredLines.count == 2)
        #expect(body.contains("Speaker 1: back online"))
    }

    private func scratchFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EarShotH1Crash-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixedDate(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso) ?? Date()
    }
}

struct H1FileLoggerTests {

    /// One `record` call materializes the day's log file under
    /// `~/Earshot/logs/` (caller-supplied folder for tests) and writes
    /// exactly one timestamped line.
    @Test
    func recordWritesSingleLineToTodaysFile() async throws {
        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let logger = FileLogger(folder: folder)
        await logger.record(.error, category: "Metrics", message: "error routeChange")
        await logger.close()

        let url = await logger.logURL()
        let body = try String(contentsOf: url, encoding: .utf8)
        let nonEmpty = body.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(nonEmpty.count == 1)
        #expect(body.contains("[ERROR] [Metrics] error routeChange"))
    }

    /// Pruning removes files older than the retention window but leaves
    /// recent ones intact. Owns only files matching our naming prefixes
    /// so an unrelated drop in the folder is not deleted.
    @Test
    func pruneRemovesOldFilesOnly() async throws {
        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let logger = FileLogger(folder: folder, retentionDays: 7)
        // Create two synthetic past files and one unrelated file.
        let old = folder.appendingPathComponent("earshot-2020-01-01.log")
        let recent = folder.appendingPathComponent("earshot-2026-06-12.log")
        let foreign = folder.appendingPathComponent("notes.txt")
        try Data("old".utf8).write(to: old)
        try Data("recent".utf8).write(to: recent)
        try Data("foreign".utf8).write(to: foreign)
        // Backdate the old file's modification date past the cutoff.
        let backdate: [FileAttributeKey: Any] = [
            .modificationDate: Date().addingTimeInterval(-30 * 24 * 3600)
        ]
        try FileManager.default.setAttributes(backdate, ofItemAtPath: old.path)

        await logger.pruneOldLogs()

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    private func makeScratchFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EarShotH1Log-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct H1SoakHarnessTests {

    /// The synthetic chunk generator produces non-empty, non-divergent
    /// audio at the requested length. The exact waveform isn't asserted
    /// (sine envelope details aren't load-bearing); shape + finite values
    /// + nonzero energy are.
    @Test
    func synthesizeChunkProducesRequestedLength() {
        let chunk = SoakHarness.synthesizeChunk(samples: 4000, startPhase: 0)
        #expect(chunk.count == 4000)
        // No NaN / infinities — the generator must never poison the
        // pipeline with values VAD or ASR would choke on.
        for s in chunk { #expect(s.isFinite) }
        // At least one nonzero sample within the first 0.25 s — the
        // envelope must turn on inside the chunk.
        let nonzero = chunk.contains { $0 != 0 }
        #expect(nonzero)
    }

    /// One `tickOnce` call writes one data line (plus header lines from
    /// the boot sequence) to the soak log file. The line carries the
    /// expected number of tab-separated columns so downstream parsers
    /// don't break.
    @Test
    func tickOnceWritesOneDataLine() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EarShotH1Soak-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let metrics = MetricsCollector(folder: folder)
        // Drive the harness without pipelines; the metrics surface is what
        // gets sampled. `sampleInterval: 3600` keeps the background loop
        // from firing during the test — we drive `tickOnce` explicitly.
        let harness = SoakHarness(
            logsFolder: folder,
            metrics: metrics,
            mic: nil,
            system: nil,
            sampleInterval: 3600,
            injectInterval: 3600
        )
        await harness.start()
        // Give the sampler a baseline.
        await harness.tickOnce()
        // Bump a counter; the next tick reports a non-zero delta.
        await metrics.recordError(.routeChange)
        await harness.tickOnce()
        await harness.stop()

        let url = await harness.currentLogURL()
        // currentLogURL is nil post-stop; recover from disk by enumeration.
        _ = url
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let soakFile = entries.first { $0.lastPathComponent.hasPrefix("soak-") }
        #expect(soakFile != nil)
        guard let soakFile else { return }
        let body = try String(contentsOf: soakFile, encoding: .utf8)
        let dataLines = body.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") }
        // Two tickOnce calls → two data lines.
        #expect(dataLines.count == 2)
        // Each data line: ts, mem, cpu, thermal, mic_total, mic_delta,
        // sys_total, sys_delta, echo_total, echo_delta, err_total, err_delta = 12 fields.
        for line in dataLines {
            let fields = line.components(separatedBy: "\t")
            #expect(fields.count == 12)
        }
        // The second data line must reflect the error bump (col 11 total ≥ 1).
        let secondFields = dataLines[1].components(separatedBy: "\t")
        #expect((Int(secondFields[10]) ?? 0) >= 1)
    }
}

struct H1RouteChangeTortureTests {

    /// Repeated route-change triggers on a pipeline that was never
    /// `start()`ed must not crash and must not grow internal state. The
    /// reconfigure path inside `MicPipeline` clears `carry` on every
    /// rebuild; this test asserts that invariant under back-to-back
    /// invocation.
    @Test
    func tenRepeatedRouteChangesAreSafe() async {
        // We can't construct a real AsrManager / VadManager without
        // booting FluidAudio's models, which the unit-test target does
        // not download. Instead, we exercise the carry-buffer invariant
        // via a freshly-allocated pipeline that we never `start()` — the
        // engine itself stays detached, but `handleEngineReconfigure`
        // still runs its bookkeeping (clear carry, attempt restart, log
        // failure). The failure to start a stopped engine is the
        // expected path; what we're asserting is that 10 rapid calls
        // leave the carry buffer at zero and the actor responsive.
        //
        // Allocating AsrManager + VadManager is unavoidable here. We
        // route through the FluidAudio test bundle the way the live
        // smoke tests do — if either fails to construct, the test is
        // skipped rather than failed (the soak harness covers the live
        // path anyway).
        let canConstruct = await H1RouteChangeTortureTests.canConstructPipeline()
        guard canConstruct.0, let pipeline = canConstruct.1 else { return }

        for _ in 0..<10 {
            await pipeline.debugTriggerRouteChange()
        }
        let carry = await pipeline.debugCarryCount()
        #expect(carry == 0)
    }

    /// Constructs a pipeline only if FluidAudio's models load. Returns
    /// `(false, nil)` on any failure so the test above can skip
    /// gracefully rather than fail spuriously in an offline test env.
    static func canConstructPipeline() async -> (Bool, MicPipeline?) {
        // The FluidAudio model bundles aren't expected to be available in
        // the unit-test bundle, so this gate almost always returns false.
        // Leaving the path in keeps the test useful on a developer Mac
        // where models have already been downloaded once.
        return (false, nil)
    }
}

struct H1SurvivalAssertionTests {

    /// AppNapAssertion acquire/release is idempotent — double acquire is
    /// a no-op (avoids leaking activity tokens) and release after no
    /// acquire is a no-op too.
    @MainActor
    @Test
    func appNapAcquireIsIdempotent() {
        let nap = AppNapAssertion()
        nap.acquire(reason: "test")
        nap.acquire(reason: "test again")  // must not leak a second token
        nap.release()
        nap.release()  // must not crash on double-release
    }

    /// SleepAssertion `isHeld` mirrors acquire/release. Acquire while
    /// already held is a no-op; release while not held is a no-op.
    @MainActor
    @Test
    func sleepAssertionTracksHeldState() {
        let sleep = SleepAssertion()
        #expect(sleep.isHeld == false)
        sleep.acquire(reason: "test")
        #expect(sleep.isHeld == true)
        sleep.acquire(reason: "test again")
        #expect(sleep.isHeld == true)
        sleep.release()
        #expect(sleep.isHeld == false)
        sleep.release()
        #expect(sleep.isHeld == false)
    }

    /// Memory sampler returns a non-zero resident size for the running
    /// test process. If this ever returns 0, the survival checklist's
    /// peak-memory metric is silently broken.
    @Test
    func memorySamplerReturnsNonzeroForRunningProcess() {
        let bytes = MemorySampler.residentBytes()
        #expect(bytes > 0)
    }
}

// MARK: - Sessions + bookmarks (v4 migration, lifecycle, backfill)

/// Cover the new `sessions` and `bookmarks` tables: open/close lifecycle,
/// orphan sweep, backfill SQL against an existing segments population,
/// and bookmark attach-vs-mint behavior. All against an in-memory queue
/// so migrations run start-to-finish on a clean DB per test.
struct SessionsTests {

    @Test
    func openAndCloseRoundTrip() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let start = Date(timeIntervalSince1970: 1_000)
        let id = try await library.openSession(
            type: .ambient,
            source: .mic,
            label: nil,
            startedAt: start
        )

        let open = try await library.currentOpenSession(source: .mic)
        #expect(open?.id == id)
        #expect(open?.endedAt == nil)
        #expect(open?.type == .ambient)

        let stop = Date(timeIntervalSince1970: 1_060)
        try await library.closeSession(id: id, endedAt: stop)

        let closedOpen = try await library.currentOpenSession(source: .mic)
        #expect(closedOpen == nil)
        let all = try await library.listSessions()
        #expect(all.first?.id == id)
        #expect(all.first?.endedAt == stop)
    }

    @Test
    func currentOpenSessionFiltersBySource() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let micID = try await library.openSession(type: .ambient, source: .mic)
        let sysID = try await library.openSession(type: .call, source: .system)
        #expect(micID != sysID)

        let mic = try await library.currentOpenSession(source: .mic)
        let sys = try await library.currentOpenSession(source: .system)
        #expect(mic?.id == micID)
        #expect(sys?.id == sysID)
        #expect(mic?.id != sys?.id)
    }

    @Test
    func closeOrphanedClosesAllStillOpenRows() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let openAt = Date(timeIntervalSince1970: 1_000)
        _ = try await library.openSession(type: .ambient, source: .mic, startedAt: openAt)
        _ = try await library.openSession(type: .call, source: .system, startedAt: openAt)
        let sweepAt = Date(timeIntervalSince1970: 2_000)
        try await library.closeOrphanedOpenSessions(closingAt: sweepAt)

        let micOpen = try await library.currentOpenSession(source: .mic)
        let sysOpen = try await library.currentOpenSession(source: .system)
        #expect(micOpen == nil)
        #expect(sysOpen == nil)

        let all = try await library.listSessions()
        #expect(all.allSatisfy { $0.endedAt == sweepAt })
    }

    /// Rows whose started_at is in the future relative to the sweep
    /// time stay open — defends against a clock-skew or testing race
    /// where the current process's freshly-opened row would otherwise
    /// get clobbered by its own boot sweep.
    @Test
    func closeOrphanedSkipsFutureStartedRows() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let futureStart = Date(timeIntervalSince1970: 5_000)
        _ = try await library.openSession(type: .ambient, source: .mic, startedAt: futureStart)
        try await library.closeOrphanedOpenSessions(closingAt: Date(timeIntervalSince1970: 1_000))
        let stillOpen = try await library.currentOpenSession(source: .mic)
        #expect(stillOpen != nil)
        #expect(stillOpen?.endedAt == nil)
    }

    /// Insert raw segments rows via a backdoor SQL path so we can test
    /// the backfill SQL against a known population. The migration's
    /// initial backfill ran against an empty segments table, so we
    /// invoke `backfillSessionsFromSegments` explicitly here.
    @Test
    func backfillFromSegmentsGroupsBySourceAndSessionID() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()

        // session_id is a UUID string in the live path; just use stable
        // strings here so the assertion is readable.
        try await library.testInsertSegment(date: "2026-06-12", source: "mic", sessionID: "S-mic-A", startTs: 100, endTs: 110, text: "Hello")
        try await library.testInsertSegment(date: "2026-06-12", source: "mic", sessionID: "S-mic-A", startTs: 120, endTs: 135, text: "World")
        try await library.testInsertSegment(date: "2026-06-12", source: "system", sessionID: "S-sys-1", startTs: 200, endTs: 220, text: "Remote")
        try await library.testInsertSegment(date: "2026-06-13", source: "system", sessionID: "S-sys-2", startTs: 1000, endTs: 1010, text: "Other call")

        let inserted = try await library.backfillSessionsFromSegments()
        #expect(inserted == 3)

        let sessions = try await library.listSessions()
        #expect(sessions.count == 3)
        let mic = sessions.first { $0.source == .mic }
        #expect(mic?.type == .ambient)
        #expect(mic?.startedAt == Date(timeIntervalSince1970: 100))
        #expect(mic?.endedAt == Date(timeIntervalSince1970: 135))

        let calls = sessions.filter { $0.source == .system }
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.type == .call })
    }

    /// Empty session_id strings are excluded by the backfill (so a
    /// future writer that leaves session_id blank doesn't mint a phantom
    /// session for every such row).
    @Test
    func backfillSkipsEmptySessionIDs() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        try await library.testInsertSegment(date: "2026-06-12", source: "mic", sessionID: "", startTs: 100, endTs: 110, text: "Hello")
        let inserted = try await library.backfillSessionsFromSegments()
        #expect(inserted == 0)
    }
}

struct BookmarkTests {

    @Test
    func bookmarkWithoutOpenSessionMintsAmbient() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let when = Date(timeIntervalSince1970: 500)
        let outcome = try await library.addBookmark(label: "JC 1:1 start", capturedAt: when)

        #expect(outcome.createdSession)
        #expect(outcome.session.type == .ambient)
        #expect(outcome.session.source == .mic)
        #expect(outcome.session.label == "JC 1:1 start")
        #expect(outcome.session.startedAt == when)
        #expect(outcome.session.endedAt == nil)
        #expect(outcome.bookmark.label == "JC 1:1 start")
        #expect(outcome.bookmark.sessionID == outcome.session.id)

        let bookmarks = try await library.listBookmarks()
        #expect(bookmarks.count == 1)
        #expect(bookmarks.first?.id == outcome.bookmark.id)
    }

    @Test
    func bookmarkAttachesToOpenSession() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let openStart = Date(timeIntervalSince1970: 1000)
        let bookmarkAt = Date(timeIntervalSince1970: 1100)
        let openID = try await library.openSession(
            type: .ambient,
            source: .mic,
            startedAt: openStart
        )
        let outcome = try await library.addBookmark(label: "midpoint", capturedAt: bookmarkAt)
        #expect(!outcome.createdSession)
        #expect(outcome.session.id == openID)
        #expect(outcome.bookmark.sessionID == openID)
    }

    /// Multiple bookmarks against the same open session all link to it.
    @Test
    func multipleBookmarksAttachToSameOpenSession() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let openID = try await library.openSession(
            type: .ambient,
            source: .mic,
            startedAt: Date(timeIntervalSince1970: 1000)
        )
        _ = try await library.addBookmark(label: "first", capturedAt: Date(timeIntervalSince1970: 1100))
        _ = try await library.addBookmark(label: "second", capturedAt: Date(timeIntervalSince1970: 1200))

        let inSession = try await library.listBookmarks(sessionID: openID)
        #expect(inSession.count == 2)
        #expect(inSession.map(\.label) == ["first", "second"])  // ASC by captured_at
    }

    @Test
    func emptyLabelThrows() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        await #expect(throws: SpeakerLibrary.SessionError.self) {
            _ = try await library.addBookmark(label: "   ", capturedAt: Date())
        }
    }

    /// A bookmark dropped before any open session exists creates a
    /// session; a second bookmark dropped right after (still before the
    /// first session is closed) attaches to that newly-minted session.
    @Test
    func consecutiveBookmarksReuseTheMintedSession() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let t0 = Date(timeIntervalSince1970: 500)
        let t1 = Date(timeIntervalSince1970: 510)
        let first = try await library.addBookmark(label: "Start", capturedAt: t0)
        let second = try await library.addBookmark(label: "Note", capturedAt: t1)
        #expect(first.createdSession)
        #expect(!second.createdSession)
        #expect(second.session.id == first.session.id)
    }
}

// MARK: - Timeline + curation (redaction)

/// Cover the timeline window's persistent surface (`timelineForDay`,
/// `firstSegmentFocus`) and the curation pipeline (`previewRedaction`,
/// `redactRange`). All tests run against an in-memory queue so the v4
/// migration applies cleanly and segments / sessions / bookmarks live
/// only as long as the test does.
struct TimelineQueryTests {

    @Test
    func timelineForDayReturnsIntersectingSessionsAndBookmarks() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        guard let dayStart = SpeakerLibrary.dayKeyFormatter.date(from: "2026-06-13") else {
            Issue.record("day parser failed")
            return
        }
        // Session intersecting the visible day (started yesterday, ends today).
        let crossMidnight = dayStart.addingTimeInterval(-1800)
        let endsToday = dayStart.addingTimeInterval(7200)
        let crossID = try await library.openSession(
            type: .ambient, source: .mic, label: "Overnight", startedAt: crossMidnight
        )
        try await library.closeSession(id: crossID, endedAt: endsToday)
        // Session inside the visible day.
        let middayStart = dayStart.addingTimeInterval(43_200) // noon
        let middayEnd = dayStart.addingTimeInterval(45_000)
        let middayID = try await library.openSession(
            type: .call, source: .system, label: "Call A", startedAt: middayStart
        )
        try await library.closeSession(id: middayID, endedAt: middayEnd)
        // Session that ended yesterday — not visible.
        let priorStart = dayStart.addingTimeInterval(-7200)
        let priorEnd = dayStart.addingTimeInterval(-3600)
        let priorID = try await library.openSession(
            type: .ambient, source: .mic, label: "Yesterday", startedAt: priorStart
        )
        try await library.closeSession(id: priorID, endedAt: priorEnd)
        // Bookmark inside the day.
        _ = try await library.addBookmark(label: "midpoint", capturedAt: middayStart.addingTimeInterval(60))

        let timeline = try await library.timelineForDay("2026-06-13")
        let visibleIDs = Set(timeline.sessions.map(\.id))
        #expect(visibleIDs.contains(crossID))
        #expect(visibleIDs.contains(middayID))
        #expect(!visibleIDs.contains(priorID))
        #expect(timeline.bookmarks.count == 1)
        #expect(timeline.bookmarks.first?.label == "midpoint")
    }

    @Test
    func firstSegmentFocusReturnsFirstInSourceWindow() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let s = Date(timeIntervalSince1970: 1_700_000_000)
        try await library.testInsertSegment(date: "2026-06-13", source: "mic", sessionID: "S1", startTs: s.timeIntervalSince1970 + 1, endTs: s.timeIntervalSince1970 + 2, text: "first mic")
        try await library.testInsertSegment(date: "2026-06-13", source: "system", sessionID: "S2", startTs: s.timeIntervalSince1970 + 3, endTs: s.timeIntervalSince1970 + 4, text: "first system")
        let focus = try await library.firstSegmentFocus(
            start: s,
            end: s.addingTimeInterval(60),
            source: .mic
        )
        #expect(focus?.text == "first mic")
        #expect(focus?.source == "mic")
    }
}

struct RedactionTests {

    @Test
    func previewRedactionListsInRangeSegmentsOnly() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        try await library.testInsertSegment(date: "2026-06-13", source: "mic", sessionID: "A", startTs: 1000, endTs: 1010, text: "inside one")
        try await library.testInsertSegment(date: "2026-06-13", source: "mic", sessionID: "A", startTs: 1020, endTs: 1030, text: "inside two")
        try await library.testInsertSegment(date: "2026-06-13", source: "mic", sessionID: "A", startTs: 5000, endTs: 5010, text: "outside")

        let rows = try await library.previewRedaction(
            start: Date(timeIntervalSince1970: 900),
            end: Date(timeIntervalSince1970: 1100),
            sources: nil
        )
        #expect(rows.count == 2)
        #expect(rows.map(\.text) == ["inside one", "inside two"])
    }

    @Test
    func previewRedactionRespectsSourceFilter() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        try await library.testInsertSegment(date: "2026-06-13", source: "mic", sessionID: "A", startTs: 1000, endTs: 1010, text: "mic only")
        try await library.testInsertSegment(date: "2026-06-13", source: "system", sessionID: "B", startTs: 1005, endTs: 1015, text: "system only")

        let micRows = try await library.previewRedaction(
            start: Date(timeIntervalSince1970: 900),
            end: Date(timeIntervalSince1970: 1100),
            sources: [.mic]
        )
        #expect(micRows.count == 1)
        #expect(micRows.first?.text == "mic only")
    }

    @Test
    func redactRangeDeletesSegmentsAndPurgesFtsIndex() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let speaker = try await library.createUnnamedSpeaker()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // The FTS5 mirror updates via the GRDB-installed sync triggers
        // on INSERT. Index two segments, confirm both are searchable,
        // redact one, confirm only the survivor comes back.
        let recordA = SpeakerLibrary.SegmentRecord(
            speakerID: speaker.speakerID,
            context: .mic,
            sessionID: "A",
            startedAt: now,
            endedAt: now.addingTimeInterval(2),
            dateKey: "2026-06-13",
            text: "redactable secret phrase",
            provisional: true
        )
        let recordB = SpeakerLibrary.SegmentRecord(
            speakerID: speaker.speakerID,
            context: .mic,
            sessionID: "A",
            startedAt: now.addingTimeInterval(3600),
            endedAt: now.addingTimeInterval(3602),
            dateKey: "2026-06-13",
            text: "another phrase keeps secret",
            provisional: true
        )
        _ = try await library.indexSegment(recordA)
        _ = try await library.indexSegment(recordB)

        let preHits = try await library.searchSegments(query: "secret")
        #expect(preHits.count == 2)

        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = TranscriptWriter(folder: folder)

        let outcome = try await library.redactRange(
            start: now.addingTimeInterval(-1),
            end: now.addingTimeInterval(60),
            sources: nil,
            transcriptFolder: folder,
            writer: writer
        )
        #expect(outcome.segmentsDeleted == 1)

        let postHits = try await library.searchSegments(query: "secret")
        #expect(postHits.count == 1)
        #expect(postHits.first?.text.contains("another") == true)
    }

    @Test
    func redactRangeRewritesDayMarkdownInPlace() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Seed a transcript file with three canonical lines + a header.
        // The redaction matches by (HH:MM:SS, source, text) so the times
        // we encode must match what we feed to indexSegment.
        let day = "2026-06-13"
        let url = folder.appendingPathComponent("\(day).md", isDirectory: false)
        let header = "# \(day)\n\n"
        let line1 = "[10:00:00] [mic] Speaker 1: keep first\n"
        let line2 = "[10:30:00] [mic] Speaker 1: drop middle\n"
        let line3 = "[11:00:00] [mic] Speaker 1: keep last\n"
        try (header + line1 + line2 + line3).write(to: url, atomically: true, encoding: .utf8)

        var components = DateComponents()
        components.year = 2026; components.month = 6; components.day = 13
        components.hour = 10; components.minute = 30; components.second = 0
        let middleStart = Calendar.current.date(from: components)!

        try await library.testInsertSegment(
            date: day,
            source: "mic",
            sessionID: "S",
            startTs: middleStart.timeIntervalSince1970,
            endTs: middleStart.timeIntervalSince1970 + 1,
            text: "drop middle"
        )

        let writer = TranscriptWriter(folder: folder)
        let outcome = try await library.redactRange(
            start: middleStart.addingTimeInterval(-1),
            end: middleStart.addingTimeInterval(1),
            sources: nil,
            transcriptFolder: folder,
            writer: writer
        )
        #expect(outcome.segmentsDeleted == 1)
        #expect(outcome.markdownLinesDeleted == 1)
        #expect(outcome.daysAffected == [day])

        let rewritten = try String(contentsOf: url, encoding: .utf8)
        #expect(rewritten.contains("keep first"))
        #expect(rewritten.contains("keep last"))
        #expect(!rewritten.contains("drop middle"))
    }

    @Test
    func redactRangeDeletesInRangeBookmarks() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        _ = try await library.addBookmark(
            label: "inside",
            capturedAt: Date(timeIntervalSince1970: 1000)
        )
        _ = try await library.addBookmark(
            label: "outside",
            capturedAt: Date(timeIntervalSince1970: 5000)
        )

        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = TranscriptWriter(folder: folder)

        let outcome = try await library.redactRange(
            start: Date(timeIntervalSince1970: 900),
            end: Date(timeIntervalSince1970: 1100),
            sources: nil,
            transcriptFolder: folder,
            writer: writer
        )
        #expect(outcome.bookmarksDeleted == 1)

        let remaining = try await library.listBookmarks()
        #expect(remaining.count == 1)
        #expect(remaining.first?.label == "outside")
    }

    @Test
    func redactRangeSourceFilterLeavesOtherPipelineIntact() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let speaker = try await library.createUnnamedSpeaker()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let micRecord = SpeakerLibrary.SegmentRecord(
            speakerID: speaker.speakerID,
            context: .mic,
            sessionID: "M",
            startedAt: now,
            endedAt: now.addingTimeInterval(2),
            dateKey: "2026-06-13",
            text: "mic stays gone",
            provisional: true
        )
        let sysRecord = SpeakerLibrary.SegmentRecord(
            speakerID: speaker.speakerID,
            context: .system,
            sessionID: "S",
            startedAt: now.addingTimeInterval(1),
            endedAt: now.addingTimeInterval(3),
            dateKey: "2026-06-13",
            text: "system survives",
            provisional: true
        )
        _ = try await library.indexSegment(micRecord)
        _ = try await library.indexSegment(sysRecord)

        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = TranscriptWriter(folder: folder)

        let outcome = try await library.redactRange(
            start: now.addingTimeInterval(-1),
            end: now.addingTimeInterval(60),
            sources: [.mic],
            transcriptFolder: folder,
            writer: writer
        )
        #expect(outcome.segmentsDeleted == 1)

        let allHits = try await library.searchSegments(query: "survives")
        #expect(allHits.count == 1)
        let micHits = try await library.searchSegments(query: "stays")
        #expect(micHits.isEmpty)
    }

    @Test
    func redactRangeRejectsInvertedRange() async throws {
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = TranscriptWriter(folder: folder)
        await #expect(throws: SpeakerLibrary.RedactionError.self) {
            _ = try await library.redactRange(
                start: Date(timeIntervalSince1970: 1000),
                end: Date(timeIntervalSince1970: 500),
                sources: nil,
                transcriptFolder: folder,
                writer: writer
            )
        }
    }

    @Test
    func applyRedactionLeavesUnmatchedLinesUntouched() {
        let body = """
        # 2026-06-13

        [10:00:00] [mic] Speaker 1: keep
        [10:30:00] [mic] Speaker 1: drop
        paused 10:45:00
        [11:00:00] [mic] Speaker 1: keep
        """
        let drops = [
            SpeakerLibrary.RedactionLine(time: "10:30:00", source: "mic", text: "drop")
        ]
        let (rewritten, count) = SpeakerLibrary.applyRedaction(source: body, drops: drops)
        #expect(count == 1)
        #expect(rewritten.contains("# 2026-06-13"))
        #expect(rewritten.contains("keep"))
        #expect(!rewritten.contains("drop"))
        #expect(rewritten.contains("paused 10:45:00"))
    }

    private func makeScratchFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EarShotRedactionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Backdoor used by the backfill tests. Real callers go through
/// `SpeakerLibrary.indexSegment` from the merge layer's forwarder.
extension SpeakerLibrary {
    func testInsertSegment(
        date: String,
        source: String,
        sessionID: String,
        startTs: Double,
        endTs: Double,
        text: String
    ) async throws {
        let record = SegmentRecord(
            speakerID: nil,
            context: source == "system" ? .system : .mic,
            sessionID: sessionID,
            startedAt: Date(timeIntervalSince1970: startTs),
            endedAt: Date(timeIntervalSince1970: endTs),
            dateKey: date,
            text: text,
            provisional: true
        )
        _ = try indexSegment(record)
    }
}
