//
//  MergeLayer.swift
//  EarShot
//

import Foundation
import os

/// CLAUDE.md rules 7 + 8: the merge layer is the single point that owns
/// echo dedupe (rule 7) and persistent speaker identity (rule 8).
///
/// PRD R3: "If a mic segment's text closely matches a system segment within
/// a 2 s window, the mic copy is dropped and the system copy (correct
/// speaker) wins." Match is on normalized token overlap (Jaccard), not
/// exact string, since ASR rarely produces identical tokenizations between
/// raw-room mic audio and clean-codec system audio.
///
/// Mic segments are held briefly when the system pipeline is active so a
/// slightly-late system segment can win. When the system pipeline is
/// inactive (no allow-listed app is producing audio), mic segments forward
/// immediately — there is nothing on the other side that could produce an
/// echo, and the user should not pay for the dedupe latency.
///
/// S3 adds identity resolution. Pipelines now hand the merge layer a
/// `FinalizedSegment` carrier that includes the embedding + chunk-local
/// slot label + session token; the merge layer asks `IdentityResolver` to
/// rewrite the segment's `speakerLabel` to a persistent display label
/// before dedupe and forwarding. Rule 8 is satisfied because no other
/// component (not the pipelines, not the diarizers) ever touches identity.
actor MergeLayer {
    enum DropReason: Sendable {
        case echo
    }

    /// Carrier from pipelines into the merge layer. Wraps a built segment
    /// with everything `IdentityResolver` needs to map the chunk-local
    /// label to a persistent identity.
    struct FinalizedSegment: Sendable {
        let segment: LiveTranscript.Segment
        /// 256-d WeSpeaker embedding for the utterance. May be nil if the
        /// extractor failed (very short clip, model hiccup) — the resolver
        /// falls back to cache or to minting a fresh unnamed speaker.
        let embedding: [Float]?
        /// Chunk-local Sortformer label (e.g. "Speaker 1"). Used as the
        /// per-session cache key by `IdentityResolver`. Empty string means
        /// the diarizer had no label for this utterance (very early in a
        /// session, before any overlap was observed) — in that case we
        /// skip identity resolution and leave the segment label as-is.
        let slotLabel: String
        /// `SpeakerLibrary.SessionToken.id` for the emitting pipeline's
        /// current session. Fresh per pipeline start.
        let sessionID: UUID
        /// Utterance duration in seconds; resolver passes this to
        /// `SpeakerLibrary.qualityFromDuration` to score the stored
        /// embedding.
        let durationSeconds: Double
    }

    /// Forwarded carrier — the segment plus the identity context the
    /// resolver attached (or nil if pre-S3 / no resolver). AppDelegate
    /// uses `speakerID + sessionID + dateKey` to write the row into the
    /// SQLite segments index for FTS5 search (S4). Tests that don't care
    /// about identity can ignore the extra fields.
    struct ForwardedSegment: Sendable {
        let segment: LiveTranscript.Segment
        let speakerID: Int64?
        let sessionID: UUID?
    }

    private var onForward: (@Sendable (ForwardedSegment) -> Void)?
    private var onDropped: (@Sendable (LiveTranscript.Segment, DropReason) -> Void)?

    /// Injected by AppDelegate after onboarding. Optional so tests + the
    /// pre-S3 path can construct a merge layer without one — in that case
    /// segments pass through with their chunk-local label intact.
    private var identityResolver: IdentityResolver?

    func setHandlers(
        onForward: @escaping @Sendable (ForwardedSegment) -> Void,
        onDropped: @escaping @Sendable (LiveTranscript.Segment, DropReason) -> Void
    ) {
        self.onForward = onForward
        self.onDropped = onDropped
    }

    func setIdentityResolver(_ resolver: IdentityResolver) {
        self.identityResolver = resolver
    }

    /// PRD R3: 2-second window.
    private let dedupeWindowSeconds: TimeInterval = 2.0

    /// Token-overlap threshold (Jaccard). 0.5 is deliberately loose: an
    /// exact-match gate would catch nothing because mic vs system ASR
    /// outputs differ in articles, contractions, and noise tokens. Tunable
    /// once real call data is available.
    static let defaultJaccardThreshold: Double = 0.5
    private let jaccardThreshold: Double

    /// Mic segments wait this long before forwarding when the system
    /// pipeline is active. This is the unavoidable latency cost of dedupe:
    /// we cannot retract a mic segment once it has reached the panel + disk,
    /// so we hold it until the matching system segment has had a fair
    /// chance to arrive.
    private let micHoldSeconds: TimeInterval = 2.0

    private struct RecentSystem {
        let segment: LiveTranscript.Segment
        let tokenSet: Set<String>
        let speakerID: Int64?
        let sessionID: UUID?
    }
    private var recentSystem: [RecentSystem] = []

    /// True while the system pipeline is producing audio (tap attached).
    private var systemActive: Bool = false

    private let log = Logger(subsystem: "com.earshot.app", category: "MergeLayer")

    init(jaccardThreshold: Double = MergeLayer.defaultJaccardThreshold) {
        self.jaccardThreshold = jaccardThreshold
    }

    func setSystemActive(_ active: Bool) {
        guard systemActive != active else { return }
        systemActive = active
        log.debug("System pipeline active: \(active)")
    }

    /// Legacy entry: a bare `LiveTranscript.Segment` (no embedding, no
    /// slot/session context). Used by tests and any pre-S3 path. Identity
    /// resolution is skipped because there is nothing to resolve from.
    func submit(_ segment: LiveTranscript.Segment) {
        runDedupeAndForward(segment, speakerID: nil, sessionID: nil)
    }

    /// S3 entry: pipelines hand the merge layer a fully populated
    /// `FinalizedSegment`. We ask the resolver to rewrite the speaker
    /// label, then run the same dedupe + forward path as the legacy entry.
    func submit(_ finalized: FinalizedSegment) async {
        var working = finalized.segment
        var resolvedSpeakerID: Int64? = nil

        if let resolver = self.identityResolver, !finalized.slotLabel.isEmpty {
            let context: SpeakerLibrary.Context = (finalized.segment.source == .mic) ? .mic : .system
            let resolution = await resolver.resolve(
                source: context,
                sessionID: finalized.sessionID,
                slotLabel: finalized.slotLabel,
                embedding: finalized.embedding,
                durationSeconds: finalized.durationSeconds
            )
            resolvedSpeakerID = resolution.speakerID == 0 ? nil : resolution.speakerID
            working = LiveTranscript.Segment(
                id: finalized.segment.id,
                startedAt: finalized.segment.startedAt,
                endedAt: finalized.segment.endedAt,
                source: finalized.segment.source,
                speakerLabel: resolution.displayLabel,
                text: finalized.segment.text,
                speakerID: resolvedSpeakerID
            )
        }

        runDedupeAndForward(working, speakerID: resolvedSpeakerID, sessionID: finalized.sessionID)
    }

    private func runDedupeAndForward(_ segment: LiveTranscript.Segment, speakerID: Int64?, sessionID: UUID?) {
        switch segment.source {
        case .system:
            let tokens = Self.normalizedTokens(segment.text)
            recentSystem.append(RecentSystem(segment: segment, tokenSet: tokens, speakerID: speakerID, sessionID: sessionID))
            pruneRecentSystem(now: segment.endedAt)
            onForward?(ForwardedSegment(segment: segment, speakerID: speakerID, sessionID: sessionID))
        case .mic:
            if !systemActive {
                onForward?(ForwardedSegment(segment: segment, speakerID: speakerID, sessionID: sessionID))
                return
            }
            if let match = findEcho(for: segment) {
                log.info("Echo dropped (eager match against earlier system): mic '\(segment.text, privacy: .private)' ~= system '\(match.text, privacy: .private)'")
                onDropped?(segment, .echo)
                return
            }
            // Hold so a slightly-late system segment can still win.
            let held = HeldMic(segment: segment, speakerID: speakerID, sessionID: sessionID)
            let hold = micHoldSeconds
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
                await self?.resolveHeldMic(held)
            }
        }
    }

    private struct HeldMic: Sendable {
        let segment: LiveTranscript.Segment
        let speakerID: Int64?
        let sessionID: UUID?
    }

    private func resolveHeldMic(_ held: HeldMic) {
        if let match = findEcho(for: held.segment) {
            log.info("Echo dropped (held match against later system): mic '\(held.segment.text, privacy: .private)' ~= system '\(match.text, privacy: .private)'")
            onDropped?(held.segment, .echo)
            return
        }
        onForward?(ForwardedSegment(segment: held.segment, speakerID: held.speakerID, sessionID: held.sessionID))
    }

    private func findEcho(for mic: LiveTranscript.Segment) -> LiveTranscript.Segment? {
        let micTokens = Self.normalizedTokens(mic.text)
        guard !micTokens.isEmpty else { return nil }
        for entry in recentSystem {
            let dt = abs(mic.startedAt.timeIntervalSince(entry.segment.startedAt))
            guard dt <= dedupeWindowSeconds else { continue }
            let j = Self.jaccard(micTokens, entry.tokenSet)
            if j >= jaccardThreshold {
                return entry.segment
            }
        }
        return nil
    }

    private func pruneRecentSystem(now: Date) {
        let cutoff = now.addingTimeInterval(-(dedupeWindowSeconds + micHoldSeconds + 1.0))
        recentSystem.removeAll { $0.segment.endedAt < cutoff }
    }

    // MARK: Normalization (nonisolated so unit tests can reach them)

    /// Lowercase, strip non-alphanumeric to spaces, split on whitespace,
    /// drop single-character noise tokens. We deliberately do NOT remove
    /// stopwords — ASR-mangled stopwords ("the" vs "a") are real signal
    /// for matching identical phrases.
    nonisolated static func normalizedTokens(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        var cleaned = ""
        cleaned.reserveCapacity(lowered.count)
        for scalar in lowered.unicodeScalars {
            if scalar.properties.isAlphabetic || (scalar.value >= 48 && scalar.value <= 57) {
                cleaned.unicodeScalars.append(scalar)
            } else {
                cleaned.append(" ")
            }
        }
        return Set(
            cleaned
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { $0.count > 1 }
        )
    }

    nonisolated static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        let inter = a.intersection(b).count
        let union = a.union(b).count
        return Double(inter) / Double(union)
    }
}
