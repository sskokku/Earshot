//
//  IdentityResolver.swift
//  EarShot
//

import Foundation
import os

/// CLAUDE.md rule 8: only the merge layer touches identity. The
/// IdentityResolver is the engine that the merge layer drives — a single
/// actor that owns the mapping from chunk-local Sortformer slot labels
/// (per-pipeline, per-session) to persistent SQLite speaker ids.
///
/// Matching policy (CLAUDE.md §"Matching policy"):
///   - Cosine similarity against the library, per-speaker MAX score across
///     that speaker's embeddings.
///   - Same-context threshold: 0.65.
///   - Cross-context fallback: 0.75.
///   - Below both: mint a new persistent speaker with a stable
///     "Speaker N" display label.
///   - Every confident match (cache hit OR new same/cross match) adds a
///     fresh embedding under the matched speaker in the CALLER's context.
///     This is what makes recognition improve with use — a speaker's
///     embeddings drift to look more like the live audio over time, and
///     cross-context evidence accumulates a same-context store once it
///     starts matching.
///
/// Caching: the (source, sessionID, slotLabel) tuple keys a small in-memory
/// map. The diarizer hands us the same slot label across many segments
/// within one session; we only do the full DB query + cosine sweep on the
/// first one. Cache entries from old sessions are dead weight but
/// negligible (≤ a few per pipeline-restart per day); they clear on app
/// restart.
///
/// Logging: every decision is logged (subsystem `com.earshot.app`, category
/// `IdentityResolver`). Logs include the source pipeline, slot label,
/// candidate speaker id, similarity score, threshold, and outcome —
/// enough to tune thresholds against real voices without recompiling.
actor IdentityResolver {

    /// CLAUDE.md §"Matching policy" thresholds. Constants here so tests
    /// and future tuning have a single source of truth.
    static let defaultSameContextThreshold: Double = 0.65
    static let defaultCrossContextThreshold: Double = 0.75

    private let sameContextThreshold: Double
    private let crossContextThreshold: Double
    private let library: SpeakerLibrary
    private let log = Logger(subsystem: "com.earshot.app", category: "IdentityResolver")

    /// Outcome handed back to the merge layer. The merge layer rewrites
    /// the segment's `speakerLabel` to this label before forwarding it to
    /// the panel and disk.
    struct Resolution: Sendable, Equatable {
        let speakerID: Int64
        let displayLabel: String
    }

    private struct CacheKey: Hashable {
        let source: SpeakerLibrary.Context
        let sessionID: UUID
        let slotLabel: String
    }

    private var cache: [CacheKey: Resolution] = [:]

    init(
        library: SpeakerLibrary,
        sameContextThreshold: Double = IdentityResolver.defaultSameContextThreshold,
        crossContextThreshold: Double = IdentityResolver.defaultCrossContextThreshold
    ) {
        self.library = library
        self.sameContextThreshold = sameContextThreshold
        self.crossContextThreshold = crossContextThreshold
    }

    /// Map a chunk-local diarizer slot label to a persistent speaker
    /// identity. Adds a fresh embedding on every confident match.
    ///
    /// `embedding` may be nil when the WeSpeaker extractor failed on a
    /// short or noisy clip — in that case we still return a Resolution
    /// (cache hit if we can, freshly minted speaker otherwise) so the
    /// segment gets a stable label.
    func resolve(
        source: SpeakerLibrary.Context,
        sessionID: UUID,
        slotLabel: String,
        embedding: [Float]?,
        durationSeconds: Double
    ) async -> Resolution {
        let key = CacheKey(source: source, sessionID: sessionID, slotLabel: slotLabel)
        let sessionPrefix = String(sessionID.uuidString.prefix(8))

        if let cached = cache[key] {
            if let embedding {
                await recordEmbedding(
                    speakerID: cached.speakerID,
                    context: source,
                    vector: embedding,
                    durationSeconds: durationSeconds
                )
                log.info("[resolve] CACHE-HIT source=\(source.rawValue, privacy: .public) session=\(sessionPrefix, privacy: .public) slot=\(slotLabel, privacy: .public) → speaker=\(cached.speakerID) (\(cached.displayLabel, privacy: .public)) +embedding")
            } else {
                log.info("[resolve] CACHE-HIT source=\(source.rawValue, privacy: .public) session=\(sessionPrefix, privacy: .public) slot=\(slotLabel, privacy: .public) → speaker=\(cached.speakerID) (\(cached.displayLabel, privacy: .public)) [no embedding]")
            }
            return cached
        }

        guard let embedding else {
            // No embedding → no way to match. Mint a fresh speaker so the
            // segment still lands somewhere; don't bother recording an
            // embedding (we don't have one).
            let minted = await mintNewSpeaker()
            cache[key] = minted
            log.info("[resolve] NO-EMBEDDING source=\(source.rawValue, privacy: .public) session=\(sessionPrefix, privacy: .public) slot=\(slotLabel, privacy: .public) → minted speaker=\(minted.speakerID) (\(minted.displayLabel, privacy: .public))")
            return minted
        }

        // Same-context match first.
        let sameCandidates = (try? await library.allEmbeddings(context: source)) ?? []
        let sameBest = bestMatch(query: embedding, candidates: sameCandidates)

        if let (sid, score) = sameBest, score >= sameContextThreshold {
            let label = await displayLabel(forSpeakerID: sid)
            let res = Resolution(speakerID: sid, displayLabel: label)
            cache[key] = res
            await recordEmbedding(
                speakerID: sid,
                context: source,
                vector: embedding,
                durationSeconds: durationSeconds
            )
            log.info("[resolve] MATCH-SAME source=\(source.rawValue, privacy: .public) session=\(sessionPrefix, privacy: .public) slot=\(slotLabel, privacy: .public) → speaker=\(sid) (\(label, privacy: .public)) sim=\(Self.fmt(score)) ≥ threshold=\(Self.fmt(self.sameContextThreshold)) candidates=\(sameCandidates.count)")
            return res
        }

        // Cross-context fallback. Pull the other context's embeddings and
        // try a looser threshold.
        let otherContext: SpeakerLibrary.Context = (source == .mic) ? .system : .mic
        let crossCandidates = (try? await library.allEmbeddings(context: otherContext)) ?? []
        let crossBest = bestMatch(query: embedding, candidates: crossCandidates)

        if let (sid, score) = crossBest, score >= crossContextThreshold {
            let label = await displayLabel(forSpeakerID: sid)
            let res = Resolution(speakerID: sid, displayLabel: label)
            cache[key] = res
            // Store the fresh embedding under the CALLER'S context so a
            // same-context store accumulates for next time.
            await recordEmbedding(
                speakerID: sid,
                context: source,
                vector: embedding,
                durationSeconds: durationSeconds
            )
            log.info("[resolve] MATCH-CROSS source=\(source.rawValue, privacy: .public) session=\(sessionPrefix, privacy: .public) slot=\(slotLabel, privacy: .public) → speaker=\(sid) (\(label, privacy: .public)) sim=\(Self.fmt(score)) ≥ threshold=\(Self.fmt(self.crossContextThreshold)) other-context-candidates=\(crossCandidates.count)")
            return res
        }

        // Below both thresholds → mint a new persistent speaker and seed
        // it with this embedding.
        let sameSummary: String = sameBest.map { "speaker=\($0.0) sim=\(Self.fmt($0.1))" } ?? "n/a"
        let crossSummary: String = crossBest.map { "speaker=\($0.0) sim=\(Self.fmt($0.1))" } ?? "n/a"
        let minted = await mintNewSpeaker()
        cache[key] = minted
        if minted.speakerID != 0 {
            await recordEmbedding(
                speakerID: minted.speakerID,
                context: source,
                vector: embedding,
                durationSeconds: durationSeconds
            )
        }
        log.info("[resolve] NO-MATCH source=\(source.rawValue, privacy: .public) session=\(sessionPrefix, privacy: .public) slot=\(slotLabel, privacy: .public) best-same=[\(sameSummary, privacy: .public)] (threshold=\(Self.fmt(self.sameContextThreshold))) best-cross=[\(crossSummary, privacy: .public)] (threshold=\(Self.fmt(self.crossContextThreshold))) → minted speaker=\(minted.speakerID) (\(minted.displayLabel, privacy: .public))")
        return minted
    }

    /// Test helper: drop the in-memory cache. The DB is the persistent
    /// source of truth; this lets unit tests simulate an app restart
    /// without re-instantiating the actor.
    func clearCache() {
        cache.removeAll(keepingCapacity: false)
    }

    /// Invalidate every cache entry that resolved to `speakerID`. Called
    /// by AppDelegate after S4 renames, merges, deletes — anything that
    /// changes the persisted display label or removes the speaker. The
    /// next resolve for the same (source, session, slot) tuple will do a
    /// fresh DB lookup so the new label/identity propagates immediately
    /// without waiting for a pipeline restart.
    func invalidate(speakerID: Int64) {
        cache = cache.filter { $0.value.speakerID != speakerID }
        log.info("[invalidate] dropped cache entries for speaker=\(speakerID)")
    }

    /// Stronger sibling: drop every cache entry mapped to any speakerID
    /// in the given set. Used by merge (source dies → drop) and bulk
    /// cleanup paths.
    func invalidate(speakerIDs: Set<Int64>) {
        cache = cache.filter { !speakerIDs.contains($0.value.speakerID) }
        log.info("[invalidate] dropped cache entries for \(speakerIDs.count) speakers")
    }

    // MARK: - Matching internals

    /// Best per-speaker score across candidate embeddings. Per-speaker MAX
    /// is the standard speaker-verification choice: a speaker's nearest
    /// embedding to the query is what matters; their other embeddings might
    /// be from different acoustic conditions and dilute the signal if we
    /// averaged.
    private func bestMatch(
        query: [Float],
        candidates: [SpeakerLibrary.SpeakerEmbedding]
    ) -> (Int64, Double)? {
        var perSpeakerMax: [Int64: Double] = [:]
        for cand in candidates {
            let sim = Self.cosineSimilarity(query, cand.vector)
            if let existing = perSpeakerMax[cand.speakerID] {
                if sim > existing { perSpeakerMax[cand.speakerID] = sim }
            } else {
                perSpeakerMax[cand.speakerID] = sim
            }
        }
        return perSpeakerMax.max(by: { $0.value < $1.value }).map { ($0.key, $0.value) }
    }

    private func recordEmbedding(
        speakerID: Int64,
        context: SpeakerLibrary.Context,
        vector: [Float],
        durationSeconds: Double
    ) async {
        do {
            try await library.recordEmbedding(
                speakerID: speakerID,
                context: context,
                vector: vector,
                quality: SpeakerLibrary.qualityFromDuration(seconds: durationSeconds)
            )
        } catch {
            log.error("Embedding write failed for speaker=\(speakerID): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func mintNewSpeaker() async -> Resolution {
        do {
            let row = try await library.createUnnamedSpeaker()
            return Resolution(speakerID: row.speakerID, displayLabel: row.displayLabel)
        } catch {
            log.error("Failed to mint new speaker: \(error.localizedDescription, privacy: .public)")
            // Sentinel: speakerID=0 is invalid in SQLite AUTOINCREMENT
            // semantics; the merge layer treats this as "label only, no
            // persistent record" so the segment still renders.
            return Resolution(speakerID: 0, displayLabel: "Speaker ?")
        }
    }

    private func displayLabel(forSpeakerID id: Int64) async -> String {
        do {
            return try await library.displayLabel(forSpeakerID: id) ?? "Speaker ?"
        } catch {
            log.error("Display-label lookup failed for speaker=\(id): \(error.localizedDescription, privacy: .public)")
            return "Speaker ?"
        }
    }

    // MARK: - Cosine similarity

    /// Cosine similarity in Double precision. WeSpeaker embeddings are
    /// already L2-normalized (per FluidAudio docs), so this is equivalent
    /// to a dot product — but we compute the full form so the matcher is
    /// correct under any embedding source.
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

    private static func fmt(_ x: Double) -> String {
        String(format: "%.3f", x)
    }
}
