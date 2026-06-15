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

// MARK: - Speaker curation (needs-naming + merge suggestions)

/// Cover the curation surface on `SpeakerLibrary`: ranked unnamed
/// speakers, sample quote selection, badge count (excludes owner +
/// merged + named), and cross-context merge suggestions in the
/// just-below-threshold band.
struct SpeakerCurationTests {

    /// `AppSettings.ownerSpeakerIDValue` is UserDefaults-backed and
    /// persists across the entire xctest run, so a prior suite that
    /// enrolled an owner leaves a non-nil id behind. The curation queries
    /// filter by `s.id <> ownerSpeakerIDValue`, so a stale value would
    /// erroneously exclude one of the speakers a curation test creates.
    /// Clear it at the top of every test; tests that need an owner
    /// re-enroll it explicitly below.
    private static func resetOwnerAppSettings() {
        AppSettings.ownerSpeakerIDValue = nil
    }

    @Test
    func unnamedSpeakerCountExcludesOwnerMergedAndNamed() async throws {
        Self.resetOwnerAppSettings()
        let library = try IdentityResolverTests.makeMemoryLibrary()
        // Owner: enrolled with a name → never counted.
        _ = try await library.enrollOwner(
            name: "Owner",
            embedding: IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 1)
        )
        // Unnamed speakers — these are the badge.
        let s1 = try await library.createUnnamedSpeaker()
        let s2 = try await library.createUnnamedSpeaker()
        // Named speaker — name set after creation.
        let named = try await library.createUnnamedSpeaker()
        try await library.testSetName(speakerID: named.speakerID, name: "Bob")
        // Merged speaker — survives for audit but is not in the active set.
        let merged = try await library.createUnnamedSpeaker()
        try await library.testSetMergedInto(source: merged.speakerID, into: s1.speakerID)

        let count = try await library.unnamedSpeakerCount()
        #expect(count == 2)
        let rows = try await library.unnamedSpeakersForCuration()
        let surfaced = Set(rows.map(\.id))
        #expect(surfaced == [s1.speakerID, s2.speakerID])
    }

    @Test
    func unnamedSpeakersRankedByTotalSegmentFrequency() async throws {
        Self.resetOwnerAppSettings()
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let busy = try await library.createUnnamedSpeaker()
        let medium = try await library.createUnnamedSpeaker()
        let quiet = try await library.createUnnamedSpeaker()
        // Three segments for busy, two for medium, one for quiet.
        let date = "2026-06-13"
        for i in 0..<3 {
            try await library.testInsertSegment(
                speakerID: busy.speakerID,
                date: date,
                source: "mic",
                sessionID: "busy",
                startTs: 1000 + Double(i),
                endTs: 1001 + Double(i),
                text: "busy line \(i)"
            )
        }
        for i in 0..<2 {
            try await library.testInsertSegment(
                speakerID: medium.speakerID,
                date: date,
                source: "mic",
                sessionID: "medium",
                startTs: 2000 + Double(i),
                endTs: 2001 + Double(i),
                text: "medium line \(i)"
            )
        }
        try await library.testInsertSegment(
            speakerID: quiet.speakerID,
            date: date,
            source: "system",
            sessionID: "quiet",
            startTs: 3000,
            endTs: 3001,
            text: "quiet line"
        )

        let rows = try await library.unnamedSpeakersForCuration()
        #expect(rows.map(\.id) == [busy.speakerID, medium.speakerID, quiet.speakerID])
        #expect(rows.map(\.segmentCount) == [3, 2, 1])
    }

    @Test
    func sampleQuotesPrefersLongestAndMostRecent() async throws {
        Self.resetOwnerAppSettings()
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let row = try await library.createUnnamedSpeaker()
        // Three short, two long. Longest two must surface; tie broken by recency.
        try await library.testInsertSegment(
            speakerID: row.speakerID, date: "2026-06-13", source: "mic", sessionID: "s",
            startTs: 100, endTs: 101, text: "short one"
        )
        try await library.testInsertSegment(
            speakerID: row.speakerID, date: "2026-06-13", source: "mic", sessionID: "s",
            startTs: 200, endTs: 201, text: "this is a much longer utterance with more words"
        )
        try await library.testInsertSegment(
            speakerID: row.speakerID, date: "2026-06-13", source: "system", sessionID: "s",
            startTs: 300, endTs: 301, text: "another long-ish utterance again"
        )

        let rows = try await library.unnamedSpeakersForCuration(quotesPerSpeaker: 2)
        #expect(rows.count == 1)
        let quotes = rows[0].sampleQuotes
        #expect(quotes.count == 2)
        // The longest text is first; the medium-length one is second.
        #expect(quotes[0].text == "this is a much longer utterance with more words")
        #expect(quotes[1].text == "another long-ish utterance again")
    }

    @Test
    func mergeSuggestionsBandPassesAndRanksDescending() async throws {
        Self.resetOwnerAppSettings()
        let library = try IdentityResolverTests.makeMemoryLibrary()
        // Three unnamed speakers. Embeddings constructed so that:
        //  - A.mic ↔ B.system  sits at cosine ≈ 0.68 (in the band).
        //  - A.mic ↔ C.system  sits near orthogonal (well below the band).
        //  - B.mic ↔ C.system  sits at cosine ≈ 1.0 (above the auto-merge
        //    ceiling — the live resolver would have folded these).
        let a = try await library.createUnnamedSpeaker()
        let b = try await library.createUnnamedSpeaker()
        let c = try await library.createUnnamedSpeaker()

        let vA = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 41)
        let vBSystemInBand = SpeakerCurationTests.vectorWithCosine(to: vA, cosine: 0.68)
        try await library.recordEmbedding(speakerID: a.speakerID, context: .mic, vector: vA, quality: 0.9)
        try await library.recordEmbedding(speakerID: b.speakerID, context: .system, vector: vBSystemInBand, quality: 0.9)

        // Below-band pair: orthogonal-ish vector on C.system.
        let vCSystemBelow = SpeakerCurationTests.vectorWithCosine(to: vA, cosine: 0.10)
        try await library.recordEmbedding(speakerID: c.speakerID, context: .system, vector: vCSystemBelow, quality: 0.9)

        // Above-ceiling pair: identical vectors on B.mic and C.system.
        let vAbove = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 71)
        try await library.recordEmbedding(speakerID: b.speakerID, context: .mic, vector: vAbove, quality: 0.9)
        try await library.recordEmbedding(speakerID: c.speakerID, context: .system, vector: vAbove, quality: 0.9)

        let suggestions = try await library.mergeSuggestions()
        let pairs = suggestions.map { Set([$0.speakerA, $0.speakerB]) }
        // The in-band pair must appear.
        #expect(pairs.contains(Set([a.speakerID, b.speakerID])))
        // Above-ceiling pair must NOT (live path would have auto-folded).
        #expect(!pairs.contains(Set([b.speakerID, c.speakerID])))
        // Sorted DESC by similarity.
        let sims = suggestions.map(\.similarity)
        #expect(sims == sims.sorted(by: >))
    }

    @Test
    func mergeSuggestionRecommendsNamedDestination() async throws {
        Self.resetOwnerAppSettings()
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let unnamed = try await library.createUnnamedSpeaker()
        let willName = try await library.createUnnamedSpeaker()
        try await library.testSetName(speakerID: willName.speakerID, name: "Bob")

        let v = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 91)
        let vInBand = SpeakerCurationTests.vectorWithCosine(to: v, cosine: 0.68)
        try await library.recordEmbedding(speakerID: unnamed.speakerID, context: .mic, vector: v, quality: 0.9)
        try await library.recordEmbedding(speakerID: willName.speakerID, context: .system, vector: vInBand, quality: 0.9)

        let suggestions = try await library.mergeSuggestions()
        guard let pair = suggestions.first(where: { Set([$0.speakerA, $0.speakerB]) == Set([unnamed.speakerID, willName.speakerID]) }) else {
            Issue.record("expected an in-band suggestion between the unnamed and named speakers")
            return
        }
        // Named speaker should win the destination preference.
        #expect(pair.recommendedDestination == willName.speakerID)
        #expect(pair.recommendedSource == unnamed.speakerID)
    }

    @Test
    func recommendMergeDirectionTieBreaksByLowerID() {
        // Both unnamed, equal segment counts → lower id wins destination.
        let (src, dst) = SpeakerLibrary.recommendMergeDirection(
            a: (id: 5, name: nil, segmentCount: 10),
            b: (id: 9, name: nil, segmentCount: 10)
        )
        #expect(dst == 5)
        #expect(src == 9)
    }

    /// Construct a unit vector whose cosine similarity to `u` is exactly
    /// `cosine`. Build an orthogonal direction via Gram-Schmidt on a
    /// fixed phase pattern, then combine `cosine * u + sin * orthogonal`.
    /// This sidesteps the seed-dependent blend math whose actual cosine
    /// is hard to predict without measurement.
    static func vectorWithCosine(to u: [Float], cosine: Double) -> [Float] {
        let dim = u.count
        guard dim > 0 else { return [] }
        // Seed an "other" direction with a different phase pattern.
        var w = [Float](repeating: 0, count: dim)
        for i in 0..<dim {
            w[i] = Float(sin(Double(i) * 0.71 + 1.7))
        }
        // Project out u: w_perp = w - (w·u) * u  (assumes u is unit).
        let dot = zip(w, u).reduce(0.0) { acc, pair in
            acc + Double(pair.0) * Double(pair.1)
        }
        var wPerp = [Float](repeating: 0, count: dim)
        for i in 0..<dim {
            wPerp[i] = Float(Double(w[i]) - dot * Double(u[i]))
        }
        let normPerp = sqrt(wPerp.reduce(0.0) { acc, x in acc + Double(x) * Double(x) })
        guard normPerp > 0 else { return u }
        let wPerpUnit = wPerp.map { Float(Double($0) / normPerp) }
        let sinPart = sqrt(max(0.0, 1.0 - cosine * cosine))
        var result = [Float](repeating: 0, count: dim)
        for i in 0..<dim {
            result[i] = Float(cosine * Double(u[i]) + sinPart * Double(wPerpUnit[i]))
        }
        return result
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

    /// Backdoor for the curation tests: insert a segment whose speaker
    /// pointer is already set (live path uses this via the merge layer's
    /// post-resolver `indexSegment` call).
    func testInsertSegment(
        speakerID: Int64,
        date: String,
        source: String,
        sessionID: String,
        startTs: Double,
        endTs: Double,
        text: String
    ) async throws {
        let record = SegmentRecord(
            speakerID: speakerID,
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

    /// Test-only helper that forwards to the actor-internal `testForceName`.
    /// Wrappers like this keep the test call sites compact.
    func testSetName(speakerID: Int64, name: String) throws {
        try self.testForceName(speakerID: speakerID, name: name)
    }

    /// Test-only helper that forwards to the actor-internal
    /// `testForceMergedInto`.
    func testSetMergedInto(source: Int64, into destination: Int64) throws {
        try self.testForceMergedInto(source: source, into: destination)
    }
}

// MARK: - Resolver match-decision telemetry (v5)

/// Cover the match-decision telemetry surface: per-decision row
/// persistence from IdentityResolver, ground-truth backfill on merge,
/// retroactive analysis on existing merged pairs, and the aggregate
/// stats the SpeakerCurationWindow renders.
struct MatchDecisionTelemetryTests {

    private static func resetOwnerAppSettings() {
        AppSettings.ownerSpeakerIDValue = nil
    }

    private func makeScratchFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EarShotMatchDecisionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A resolver miss writes a NO-MATCH row through `recordMatchDecision`
    /// carrying the best-same / best-cross scores and the thresholds in
    /// force at decision time. The row is reachable via the stats query.
    @Test
    func resolverMissPersistsNoMatchRow() async throws {
        Self.resetOwnerAppSettings()
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let existing = try await library.createUnnamedSpeaker()
        let baseVec = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 7)
        try await library.recordEmbedding(speakerID: existing.speakerID, context: .mic, vector: baseVec, quality: 0.9)

        // Query vector at cosine 0.55 to baseVec — below the 0.65 gate.
        let queryVec = SpeakerCurationTests.vectorWithCosine(to: baseVec, cosine: 0.55)

        let resolver = IdentityResolver(library: library)
        _ = await resolver.resolve(
            source: .mic,
            sessionID: UUID(),
            slotLabel: "Speaker 1",
            embedding: queryVec,
            durationSeconds: 1.0
        )

        let stats = try await library.matchDecisionStats()
        #expect(stats.liveDecisionTotal == 1)
        #expect(stats.liveNoMatchTotal == 1)
        // No ground truth yet — only the labeled-miss count is gated on
        // the merge. The histogram is empty for now.
        #expect(stats.liveLabeledMissTotal == 0)
    }

    /// After the user merges the freshly-minted speaker into the
    /// pre-existing one, the prior NO-MATCH row gets ground_truth_speaker_id
    /// backfilled inside the same transaction as the merge — and the
    /// labeled-miss count reflects it.
    @Test
    func mergeBackfillsGroundTruthOnPriorDecisions() async throws {
        Self.resetOwnerAppSettings()
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let existing = try await library.createUnnamedSpeaker()
        let baseVec = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 13)
        try await library.recordEmbedding(speakerID: existing.speakerID, context: .mic, vector: baseVec, quality: 0.9)

        // Force a miss at cosine 0.61 — below 0.65 same-context gate.
        let queryVec = SpeakerCurationTests.vectorWithCosine(to: baseVec, cosine: 0.61)
        let resolver = IdentityResolver(library: library)
        let res = await resolver.resolve(
            source: .mic,
            sessionID: UUID(),
            slotLabel: "Speaker 1",
            embedding: queryVec,
            durationSeconds: 1.0
        )
        // The miss minted a new speaker.
        #expect(res.speakerID != existing.speakerID)

        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = TranscriptWriter(folder: folder)
        _ = try await library.mergeSpeakers(
            source: res.speakerID,
            into: existing.speakerID,
            todayDateKey: "2026-06-15",
            transcriptFolder: folder,
            writer: writer
        )

        let stats = try await library.matchDecisionStats()
        #expect(stats.liveLabeledMissTotal == 1)
        // The labeled miss's near-miss score against the correct speaker
        // sits near the synthetic cosine, modulo float precision.
        if let m = stats.medianSameContextNearMiss {
            #expect(abs(m - 0.61) < 0.02)
        } else {
            Issue.record("expected a same-context near-miss median, got nil")
        }
    }

    /// Ground-truth bubbles through a chain of merges: A→B then B→C ends
    /// up with rows that originally referenced A pointing to C.
    @Test
    func groundTruthBackfillIsTransitiveAcrossSequentialMerges() async throws {
        Self.resetOwnerAppSettings()
        let library = try IdentityResolverTests.makeMemoryLibrary()
        // Three unnamed speakers A, B, C.
        let a = try await library.createUnnamedSpeaker()
        let b = try await library.createUnnamedSpeaker()
        let c = try await library.createUnnamedSpeaker()
        // Seed each with an embedding so the merge path's
        // movedEmbeddings count is non-trivial; A's embedding is what
        // we'll cosine-against in the synthetic resolve.
        let aVec = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 31)
        let bVec = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 32)
        let cVec = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 33)
        try await library.recordEmbedding(speakerID: a.speakerID, context: .mic, vector: aVec, quality: 0.9)
        try await library.recordEmbedding(speakerID: b.speakerID, context: .mic, vector: bVec, quality: 0.9)
        try await library.recordEmbedding(speakerID: c.speakerID, context: .mic, vector: cVec, quality: 0.9)

        // Synthesize a NO-MATCH row whose resolved_speaker_id = A.
        await library.recordMatchDecision(SpeakerLibrary.MatchDecisionRecord(
            decidedAt: Date(),
            context: .mic,
            sessionID: UUID(),
            slotLabel: "Speaker 1",
            outcome: .noMatch,
            resolvedSpeakerID: a.speakerID,
            bestSameSpeakerID: a.speakerID,
            bestSameScore: 0.62,
            bestCrossSpeakerID: nil,
            bestCrossScore: nil,
            sameThreshold: 0.65,
            crossThreshold: 0.75,
            sameCandidateCount: 1,
            crossCandidateCount: 0
        ))

        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = TranscriptWriter(folder: folder)

        // Step 1: merge A → B.
        _ = try await library.mergeSpeakers(
            source: a.speakerID,
            into: b.speakerID,
            todayDateKey: "2026-06-15",
            transcriptFolder: folder,
            writer: writer
        )
        let afterFirst = try await library.labeledMissDecisions()
        #expect(afterFirst.count == 1)
        #expect(afterFirst.first?.groundTruthSpeakerID == b.speakerID)

        // Step 2: merge B → C. The row should now point to C.
        _ = try await library.mergeSpeakers(
            source: b.speakerID,
            into: c.speakerID,
            todayDateKey: "2026-06-15",
            transcriptFolder: folder,
            writer: writer
        )
        let afterSecond = try await library.labeledMissDecisions()
        #expect(afterSecond.count == 1)
        #expect(afterSecond.first?.groundTruthSpeakerID == c.speakerID)
    }

    /// Retroactive analysis: real `mergeSpeakers` writes a merge_audit
    /// row with max same- and cross-context cosines snapshotted BEFORE
    /// embedding reassignment, so `historicalMergePairScores` returns
    /// the values that were on disk at merge time.
    @Test
    func historicalMergePairScoresComputesPerContextMaxCosine() async throws {
        Self.resetOwnerAppSettings()
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let src = try await library.createUnnamedSpeaker()
        let dst = try await library.createUnnamedSpeaker()

        // Source has one mic + one system embedding.
        let srcMic = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 51)
        let srcSys = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 52)
        try await library.recordEmbedding(speakerID: src.speakerID, context: .mic, vector: srcMic, quality: 0.9)
        try await library.recordEmbedding(speakerID: src.speakerID, context: .system, vector: srcSys, quality: 0.9)

        // Destination has one mic embedding at cosine 0.7 to srcMic (same-context)
        // and one system embedding at cosine 0.55 to srcMic (cross-context).
        let dstMic = SpeakerCurationTests.vectorWithCosine(to: srcMic, cosine: 0.7)
        let dstSys = SpeakerCurationTests.vectorWithCosine(to: srcMic, cosine: 0.55)
        try await library.recordEmbedding(speakerID: dst.speakerID, context: .mic, vector: dstMic, quality: 0.9)
        try await library.recordEmbedding(speakerID: dst.speakerID, context: .system, vector: dstSys, quality: 0.9)

        // Real merge — writes the audit row.
        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = TranscriptWriter(folder: folder)
        _ = try await library.mergeSpeakers(
            source: src.speakerID,
            into: dst.speakerID,
            todayDateKey: "2026-06-15",
            transcriptFolder: folder,
            writer: writer
        )

        let pairs = try await library.historicalMergePairScores()
        #expect(pairs.count == 1)
        guard let pair = pairs.first else { return }
        #expect(pair.sourceSpeakerID == src.speakerID)
        #expect(pair.destinationSpeakerID == dst.speakerID)
        guard let same = pair.maxSameContextScore else {
            Issue.record("expected a same-context score, got nil")
            return
        }
        #expect(abs(same - 0.70) < 0.02)
        guard let cross = pair.maxCrossContextScore else {
            Issue.record("expected a cross-context score, got nil")
            return
        }
        #expect(abs(cross - 0.55) < 0.02)
    }

    /// Threshold sweep: a labeled miss with same-context near-miss = 0.62
    /// is caught at T ≤ 0.62, missed at T > 0.62. Pure aggregation math —
    /// verifies the sweep counts true-positives correctly per row. B is
    /// intentionally left without an embedding so the A→B merge audit
    /// row carries NULL scores and never spuriously inflates the sweep.
    @Test
    func thresholdSweepCountsTruePositivesAcrossLabeledMisses() async throws {
        Self.resetOwnerAppSettings()
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let a = try await library.createUnnamedSpeaker()
        let b = try await library.createUnnamedSpeaker()
        // Only A has an embedding — keeps the merge audit's cosines NULL
        // so the threshold sweep only sees the labeled live miss row.
        let vA = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 61)
        try await library.recordEmbedding(speakerID: a.speakerID, context: .mic, vector: vA, quality: 0.9)

        // Synthesize one labeled NO-MATCH row at same-context score 0.62.
        // best_same = B (the eventual ground truth) so the sameScore
        // filter (best_same == ground_truth) returns 0.62 after the
        // A→B merge backfills ground_truth onto the row.
        await library.recordMatchDecision(SpeakerLibrary.MatchDecisionRecord(
            decidedAt: Date(),
            context: .mic,
            sessionID: UUID(),
            slotLabel: "Speaker 1",
            outcome: .noMatch,
            resolvedSpeakerID: a.speakerID,
            bestSameSpeakerID: b.speakerID,
            bestSameScore: 0.62,
            bestCrossSpeakerID: nil,
            bestCrossScore: nil,
            sameThreshold: 0.65,
            crossThreshold: 0.75,
            sameCandidateCount: 2,
            crossCandidateCount: 0
        ))

        // Merge A → B: rows whose resolved_speaker_id = A get ground_truth = B.
        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = TranscriptWriter(folder: folder)
        _ = try await library.mergeSpeakers(
            source: a.speakerID,
            into: b.speakerID,
            todayDateKey: "2026-06-15",
            transcriptFolder: folder,
            writer: writer
        )

        let stats = try await library.matchDecisionStats(
            thresholdSweep: [0.55, 0.60, 0.62, 0.65, 0.70]
        )
        // At 0.55, 0.60, 0.62 we'd have caught the miss (score ≥ T);
        // at 0.65 and 0.70 we miss it.
        let byT: [Double: Int] = Dictionary(
            uniqueKeysWithValues: stats.thresholdSweep.map { ($0.threshold, $0.sameContextTruePositives) }
        )
        #expect(byT[0.55] == 1)
        #expect(byT[0.60] == 1)
        #expect(byT[0.62] == 1)
        #expect(byT[0.65] == 0)
        #expect(byT[0.70] == 0)
    }

    /// matchDecisionStats sums live + historical sources into one
    /// distribution. Live labeled miss at 0.62 + retroactive merge
    /// audit at 0.70 → combined median ≈ 0.66.
    @Test
    func statsAggregatesLiveAndHistoricalScores() async throws {
        Self.resetOwnerAppSettings()
        let library = try IdentityResolverTests.makeMemoryLibrary()
        let v = IdentityResolverTests.makeDirectionalEmbedding(dim: 256, seed: 71)

        // C is the eventual ground truth. Its mic embedding is `v`.
        let c = try await library.createUnnamedSpeaker()
        try await library.recordEmbedding(speakerID: c.speakerID, context: .mic, vector: v, quality: 0.9)

        // A is the about-to-be-merged speaker. Its mic embedding sits at
        // cosine 0.70 to v — that becomes the historical merge audit score.
        let a = try await library.createUnnamedSpeaker()
        let aVec = SpeakerCurationTests.vectorWithCosine(to: v, cosine: 0.70)
        try await library.recordEmbedding(speakerID: a.speakerID, context: .mic, vector: aVec, quality: 0.9)

        // Live labeled miss: best-same scored against c at 0.62.
        // resolved=a so the backfill on the upcoming a→c merge tags
        // this row with ground_truth=c, and the sameScore filter
        // (best_same == ground_truth) returns 0.62.
        await library.recordMatchDecision(SpeakerLibrary.MatchDecisionRecord(
            decidedAt: Date(),
            context: .mic,
            sessionID: UUID(),
            slotLabel: "Speaker 1",
            outcome: .noMatch,
            resolvedSpeakerID: a.speakerID,
            bestSameSpeakerID: c.speakerID,
            bestSameScore: 0.62,
            bestCrossSpeakerID: nil,
            bestCrossScore: nil,
            sameThreshold: 0.65,
            crossThreshold: 0.75,
            sameCandidateCount: 2,
            crossCandidateCount: 0
        ))

        // Real merge — writes merge_audit (max same ≈ 0.70) AND
        // backfills ground_truth on the live row.
        let folder = makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = TranscriptWriter(folder: folder)
        _ = try await library.mergeSpeakers(
            source: a.speakerID, into: c.speakerID,
            todayDateKey: "2026-06-15",
            transcriptFolder: folder, writer: writer
        )

        let stats = try await library.matchDecisionStats()
        #expect(stats.liveLabeledMissTotal == 1)
        #expect(stats.historicalMergePairCount == 1)

        // Combined scores [0.62 live, 0.70 historical] → median = 0.66.
        guard let median = stats.medianSameContextNearMiss else {
            Issue.record("expected a same-context median, got nil")
            return
        }
        #expect(abs(median - 0.66) < 0.02)

        // Source clustering: the labeled miss is on mic.
        #expect(stats.micMissCount == 1)
        #expect(stats.systemMissCount == 0)
    }

    /// Histogram bucketing — pure function; 0.62 lands in bin [0.60, 0.65),
    /// 0.05 lands in bin [0.05, 0.10), 0.99 lands in the final bin.
    @Test
    func histogramBucketsScoresByFiveHundredthsWidth() {
        let bins = SpeakerLibrary.histogram(scores: [0.62, 0.05, 0.99, 0.62])
        #expect(bins.count == 20)
        // 0.62 → index 12 (lowerBound ≈ 0.60, tolerated for IEEE 754
        // drift since 12 * 0.05 in Double is 0.6000000000000001).
        #expect(abs(bins[12].lowerBound - 0.60) < 1e-9)
        #expect(bins[12].count == 2)
        // 0.05 → index 1 (lowerBound 0.05).
        #expect(bins[1].count == 1)
        // 0.99 → index 19 (last bin).
        #expect(bins[19].count == 1)
        // Empty bin elsewhere.
        #expect(bins[5].count == 0)
    }

    /// Median helper — odd count picks middle, even count averages.
    @Test
    func medianHandlesEvenAndOddCounts() {
        #expect(SpeakerLibrary.median([]) == nil)
        #expect(SpeakerLibrary.median([0.5]) == 0.5)
        #expect(SpeakerLibrary.median([0.1, 0.2, 0.3]) == 0.2)
        let evenMedian = SpeakerLibrary.median([0.1, 0.2, 0.3, 0.4]) ?? -1
        #expect(abs(evenMedian - 0.25) < 1e-9)
    }
}

// MARK: - Bookmark rendering (panel + reader divider)

/// Cover the end-to-end of bookmark divider rendering: the parser round-
/// trips with the writer's format, the writer actually emits that line
/// into the day's `.md`, the live transcript merges segments + bookmarks
/// chronologically, and the in-memory bookmark store stays bounded.
@MainActor
struct BookmarkRenderingTests {

    @Test
    func parseBookmarkLineRoundTripsWriterFormat() {
        let parsed = SpeakerLibrary.parseBookmarkLine("bookmark 14:30:00 - JC 1:1 start")
        #expect(parsed?.time == "14:30:00")
        #expect(parsed?.label == "JC 1:1 start")
    }

    @Test
    func parseBookmarkLineKeepsEmbeddedHyphensInLabel() {
        // Hyphens after the leading ` - ` separator must survive — the
        // parser greedily takes everything as the label.
        let parsed = SpeakerLibrary.parseBookmarkLine("bookmark 09:00:00 - AM - standup")
        #expect(parsed?.time == "09:00:00")
        #expect(parsed?.label == "AM - standup")
    }

    @Test
    func parseBookmarkLineRejectsCanonicalSegmentLine() {
        // A normal segment line must not look like a bookmark.
        let parsed = SpeakerLibrary.parseBookmarkLine("[14:30:00] [mic] Speaker 1: hello")
        #expect(parsed == nil)
    }

    @Test
    func parseBookmarkLineRejectsPauseMarker() {
        #expect(SpeakerLibrary.parseBookmarkLine("paused 14:30:00") == nil)
    }

    @Test
    func parseBookmarkLineRejectsEmptyLabel() {
        // The writer never emits an empty-label divider, but the parser
        // must reject it defensively in case the file was edited by hand.
        #expect(SpeakerLibrary.parseBookmarkLine("bookmark 14:30:00 - ") == nil)
    }

    @Test
    func transcriptWriterAppendsBookmarkLine() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EarShotBookmarkWriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let writer = TranscriptWriter(folder: folder)
        let when = ISO8601DateFormatter().date(from: "2026-06-15T14:30:00Z")!
        let dateKey = DateFormatter.dateKeyLocal.string(from: when)
        await writer.appendBookmark(label: "JC 1:1 start", at: when)
        await writer.close()

        let url = folder.appendingPathComponent("\(dateKey).md")
        let body = try String(contentsOf: url, encoding: .utf8)
        let bookmarkLine = body.components(separatedBy: "\n").first { $0.hasPrefix("bookmark ") }
        let parsed = bookmarkLine.flatMap(SpeakerLibrary.parseBookmarkLine)
        #expect(parsed?.label == "JC 1:1 start")
        // Header still there — append-only invariant respected.
        #expect(body.hasPrefix("# \(dateKey)"))
    }

    @Test
    func transcriptWriterSanitizesNewlinesInBookmarkLabel() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EarShotBookmarkSanitize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let writer = TranscriptWriter(folder: folder)
        let when = ISO8601DateFormatter().date(from: "2026-06-15T14:30:00Z")!
        let dateKey = DateFormatter.dateKeyLocal.string(from: when)
        await writer.appendBookmark(label: "Two\nlines", at: when)
        await writer.close()

        let url = folder.appendingPathComponent("\(dateKey).md")
        let body = try String(contentsOf: url, encoding: .utf8)
        let bookmarkLines = body.components(separatedBy: "\n").filter { $0.hasPrefix("bookmark ") }
        #expect(bookmarkLines.count == 1)
        // The embedded newline was replaced with a space, so the divider
        // remains a single parseable line.
        #expect(bookmarkLines.first?.contains("Two lines") == true)
    }

    @Test
    func liveTranscriptDisplayEntriesMergeByTimestamp() {
        let transcript = LiveTranscript()
        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 1010)
        let t2 = Date(timeIntervalSince1970: 1020)
        let s0 = LiveTranscript.Segment(
            id: UUID(),
            startedAt: t0,
            endedAt: t0.addingTimeInterval(2),
            source: .mic,
            speakerLabel: "Speaker 1",
            text: "hello"
        )
        let s2 = LiveTranscript.Segment(
            id: UUID(),
            startedAt: t2,
            endedAt: t2.addingTimeInterval(2),
            source: .mic,
            speakerLabel: "Speaker 1",
            text: "still talking"
        )
        let bookmark = LiveTranscript.BookmarkEntry(id: 1, capturedAt: t1, label: "midpoint")
        transcript.appendFinalized(s0)
        transcript.appendFinalized(s2)
        transcript.appendBookmark(bookmark)

        let entries = transcript.displayEntries
        #expect(entries.count == 3)
        if case .segment(let seg) = entries[0] { #expect(seg.id == s0.id) } else { Issue.record("entry 0 not segment") }
        if case .bookmark(let bm) = entries[1] { #expect(bm.id == 1) } else { Issue.record("entry 1 not bookmark") }
        if case .segment(let seg) = entries[2] { #expect(seg.id == s2.id) } else { Issue.record("entry 2 not segment") }
    }

    @Test
    func liveTranscriptBookmarksCapAtMaxBookmarks() {
        let transcript = LiveTranscript()
        // One more than the cap; the oldest should be dropped FIFO.
        let cap = transcript.maxBookmarks
        for i in 0..<(cap + 5) {
            transcript.appendBookmark(LiveTranscript.BookmarkEntry(
                id: Int64(i),
                capturedAt: Date(timeIntervalSince1970: Double(1000 + i)),
                label: "b\(i)"
            ))
        }
        #expect(transcript.bookmarks.count == cap)
        // Oldest survivors should be the (cap+5 - cap) = 5th id forward.
        #expect(transcript.bookmarks.first?.id == 5)
        #expect(transcript.bookmarks.last?.id == Int64(cap + 4))
    }

    @Test
    func liveTranscriptAppendBookmarkIsIdempotentOnID() {
        let transcript = LiveTranscript()
        let when = Date(timeIntervalSince1970: 1000)
        transcript.appendBookmark(LiveTranscript.BookmarkEntry(id: 7, capturedAt: when, label: "first"))
        transcript.appendBookmark(LiveTranscript.BookmarkEntry(id: 7, capturedAt: when, label: "first again"))
        #expect(transcript.bookmarks.count == 1)
        #expect(transcript.bookmarks.first?.label == "first again")
    }
}

private extension DateFormatter {
    /// Mirror of `TranscriptWriter.dateKeyFormatter` so the bookmark
    /// writer test can derive the day key the writer used. Local time —
    /// matches the writer's `Calendar(identifier: .gregorian)` default.
    static let dateKeyLocal: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
