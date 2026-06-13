//
//  CorrectionPass.swift
//  EarShot
//

import FluidAudio
import Foundation
import os

/// PRD R6 + CLAUDE.md rule 3 — the offline accuracy-correction pass.
///
/// Runs every 5 minutes against the trailing 5 minutes of audio for each
/// pipeline. Streaming diarization (Sortformer) carries a meaningful DER
/// penalty vs offline modes; an offline re-diarization pass over the
/// recent window gives us better global context and lets the existing
/// `IdentityResolver` reconsider speaker assignments using the library's
/// current state (which may now include named speakers, merged
/// embeddings, or fresh same-context samples since the segment was first
/// written).
///
/// Architecture choices spelled out for the next chunk:
///
/// 1. **The buffer is a deliberate rule-2 exception.** Each pipeline holds
///    a rolling 5-min PCM ring (~19 MB / pipeline at 16 kHz mono Float32),
///    anchored to a wall-clock epoch so the slice math lines up with the
///    segments table. No audio touches disk — rule 5 still holds. The
///    pipelines clear the ring on pause/start so a snapshot never spans
///    a teardown gap.
///
/// 2. **Re-resolve through `IdentityResolver`, not raw cosine.** Rule 8 is
///    "merge layer owns identity"; the correction pass talks to the
///    resolver, which is also wired through the merge layer in the live
///    path. We fabricate a fresh `sessionID` per pass and per offline
///    slot so cache short-circuits don't drag stale resolutions forward.
///
/// 3. **Atomic rewrite of today's Markdown.** Same pattern as S4
///    `renameSpeaker`: pause the writer's handle, build a relabel-line
///    list keyed on (HH:MM:SS, source, text), `applyRelabel` to the
///    in-memory body, write tempfile, `FileManager.replaceItemAt` inside
///    `dbQueue.write` so a rewrite failure rolls back the DB UPDATEs.
///
/// 4. **Live panel reflects corrections silently.** No banner, no toast.
///    `LiveTranscript.applyCorrectionUpdates` swaps the affected segments
///    in place; SwiftUI redraws once per pass.
///
/// 5. **Pause under thermal pressure.** The thermal monitor flips
///    `thermalThrottle` on `.serious` / `.critical`; the next pass tick
///    is a no-op. Mirrors how the pipelines widen VAD throttling.
///
/// 6. **Dedicated DiarizerManager.** The shared `EmbeddingExtractor`
///    wraps a DiarizerManager too, but `performCompleteDiarization`
///    mutates the underlying `SpeakerManager` state across chunks. Mixing
///    that with the stateless `extractSpeakerEmbedding` calls the
///    extractor makes per-segment is fragile under concurrency. The
///    second manager costs ~250 MB of model RAM, which is fine on the
///    always-on Mac this app targets. `SpeakerManager.reset()` runs
///    before each pass so slot numbering doesn't accumulate across
///    days.
actor CorrectionPass {

    /// 5-min window per PRD R6.
    static let windowSeconds: TimeInterval = 5 * 60
    /// 5-min cadence per PRD R6.
    static let passIntervalSeconds: TimeInterval = 5 * 60

    private let library: SpeakerLibrary
    private let resolver: IdentityResolver
    private let writer: TranscriptWriter
    private let metrics: MetricsCollector
    private let liveTranscript: LiveTranscript
    private let diarizer: DiarizerManager
    private let log = Logger(subsystem: "com.earshot.app", category: "CorrectionPass")

    private weak var micPipeline: MicPipeline?
    private weak var systemPipeline: SystemAudioPipeline?

    private var runTask: Task<Void, Never>?
    private var thermalThrottle = false
    /// Tracks whether a pass is in flight so the timer can't double-fire
    /// if a pass overruns its interval.
    private var passInFlight = false

    init(
        library: SpeakerLibrary,
        resolver: IdentityResolver,
        writer: TranscriptWriter,
        metrics: MetricsCollector,
        liveTranscript: LiveTranscript,
        diarizer: DiarizerManager
    ) {
        self.library = library
        self.resolver = resolver
        self.writer = writer
        self.metrics = metrics
        self.liveTranscript = liveTranscript
        self.diarizer = diarizer
    }

    /// Boots a fresh `DiarizerManager` for the correction pass. The
    /// pyannote+WeSpeaker bundle is already on disk from S2 onboarding,
    /// so this is a cache hit + Core ML compile only.
    static func boot(
        library: SpeakerLibrary,
        resolver: IdentityResolver,
        writer: TranscriptWriter,
        metrics: MetricsCollector,
        liveTranscript: LiveTranscript
    ) async throws -> CorrectionPass {
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager()
        manager.initialize(models: models)
        return CorrectionPass(
            library: library,
            resolver: resolver,
            writer: writer,
            metrics: metrics,
            liveTranscript: liveTranscript,
            diarizer: manager
        )
    }

    // MARK: Pipeline wiring

    func setPipelines(mic: MicPipeline?, system: SystemAudioPipeline?) {
        self.micPipeline = mic
        self.systemPipeline = system
    }

    /// Mirrors `MicPipeline.setThermalPressure`. CLAUDE.md long-run
    /// survival §: pause the correction pass under `.serious` thermal
    /// state so we don't pile ANE work on top of an already-throttled
    /// system.
    func setThermalThrottle(_ on: Bool) {
        if thermalThrottle != on {
            log.info("Thermal throttle \(on ? "engaged" : "released", privacy: .public)")
        }
        thermalThrottle = on
    }

    // MARK: Lifecycle

    /// Start the 5-min cadence. Idempotent: calling twice does not stack
    /// timers.
    func start() {
        if runTask != nil { return }
        runTask = Task { [weak self] in
            // First pass waits one full interval — at boot the buffer is
            // empty and we'd just spin against nothing.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.passIntervalSeconds * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.runOnce()
            }
        }
        log.info("Correction pass scheduled every \(Int(Self.passIntervalSeconds)) s")
    }

    /// Stop the scheduler. Used on clean app shutdown so the pass
    /// doesn't fire mid-finalize.
    func stop() {
        runTask?.cancel()
        runTask = nil
    }

    /// Single pass entry point. Public so tests / debug menu items can
    /// trigger an on-demand pass.
    func runOnce() async {
        guard !passInFlight else {
            log.info("Skip: previous pass still running")
            return
        }
        if thermalThrottle {
            log.info("Skip: thermal throttle engaged")
            return
        }
        passInFlight = true
        defer { passInFlight = false }

        if let mic = micPipeline {
            let snapshot = await mic.correctionAudioSnapshot()
            await runPass(context: .mic, snapshot: snapshot)
        }
        if let system = systemPipeline {
            let snapshot = await system.correctionAudioSnapshot()
            await runPass(context: .system, snapshot: snapshot)
        }
    }

    // MARK: Pass internals

    private func runPass(
        context: SpeakerLibrary.Context,
        snapshot: CorrectionAudioSnapshot?
    ) async {
        guard let snapshot, !snapshot.samples.isEmpty else {
            log.debug("[\(context.rawValue, privacy: .public)] no audio in buffer; skip")
            return
        }

        // The window we actually correct is the intersection of the
        // buffer's coverage and the [now - 5min, now] range. With a fresh
        // buffer post-pause we may only cover the last minute, which is
        // fine.
        let bufferStart = snapshot.bufferStart
        let bufferEnd = bufferStart.addingTimeInterval(
            Double(snapshot.samples.count) / Double(snapshot.sampleRate)
        )

        // Run offline diarization. Reset the manager's SpeakerManager so
        // slot numbering doesn't accumulate across passes (each pass is
        // independent — slot labels are local to this batch).
        diarizer.speakerManager.reset()
        let offlineResult: DiarizationResult
        do {
            offlineResult = try diarizer.performCompleteDiarization(
                snapshot.samples,
                sampleRate: snapshot.sampleRate
            )
        } catch {
            log.error("[\(context.rawValue, privacy: .public)] performCompleteDiarization failed: \(error.localizedDescription, privacy: .public)")
            await metrics.recordError(.diarizerFailure)
            await metrics.recordRecoveryAttempt(.diarizerFailure)
            return
        }

        let offlineSegments = offlineResult.segments
        log.info("[\(context.rawValue, privacy: .public)] offline pass produced \(offlineSegments.count) segments over \(String(format: "%.1f", bufferEnd.timeIntervalSince(bufferStart))) s")

        // Pull the candidate DB rows.
        let candidates: [SpeakerLibrary.StoredSegment]
        do {
            candidates = try await library.segmentsInRange(
                bufferStart...bufferEnd,
                context: context
            )
        } catch {
            log.error("[\(context.rawValue, privacy: .public)] segmentsInRange failed: \(error.localizedDescription, privacy: .public)")
            await metrics.recordError(.diskWriteFailure)
            return
        }
        if candidates.isEmpty {
            log.debug("[\(context.rawValue, privacy: .public)] no in-window DB segments; nothing to correct")
            return
        }

        // Per-slot embedding cache. The offline result's segments carry
        // 256-d L2-normalized embeddings; we pick the highest-quality
        // representative per slot. One resolver call per slot, reused
        // across every DB row that the slot dominates.
        var slotEmbedding: [String: (vector: [Float], duration: Double)] = [:]
        for offline in offlineSegments {
            let dur = Double(offline.durationSeconds)
            if let existing = slotEmbedding[offline.speakerId] {
                // Prefer the longer-duration sample (higher quality proxy).
                if dur > existing.duration {
                    slotEmbedding[offline.speakerId] = (offline.embedding, dur)
                }
            } else {
                slotEmbedding[offline.speakerId] = (offline.embedding, dur)
            }
        }

        // Fresh session id so cache short-circuits in the resolver don't
        // confuse this pass with the live path's per-pipeline session.
        let passSessionID = UUID()
        var slotResolution: [String: IdentityResolver.Resolution] = [:]

        // Build updates.
        var updates: [SpeakerLibrary.CorrectionUpdate] = []
        var liveUpdates: [CorrectionLiveUpdate] = []

        for candidate in candidates {
            let segmentSpan = (
                start: candidate.startedAt.timeIntervalSince(bufferStart),
                end: candidate.endedAt.timeIntervalSince(bufferStart)
            )
            guard segmentSpan.end > segmentSpan.start else { continue }

            // Dominant offline slot by overlap-weighted vote.
            guard let dominantSlot = dominantSlot(span: segmentSpan, segments: offlineSegments) else {
                continue
            }

            // Resolve (cache per slot per pass) into a persistent speaker.
            let resolution: IdentityResolver.Resolution
            if let cached = slotResolution[dominantSlot] {
                resolution = cached
            } else {
                guard let embeddingPick = slotEmbedding[dominantSlot] else {
                    // Offline returned a slot id with no segment carrying
                    // an embedding — defensive only; shouldn't happen.
                    continue
                }
                let duration = max(0.5, embeddingPick.duration)
                let res = await resolver.resolve(
                    source: context,
                    sessionID: passSessionID,
                    slotLabel: "offline:\(dominantSlot)",
                    embedding: embeddingPick.vector,
                    durationSeconds: duration
                )
                slotResolution[dominantSlot] = res
                resolution = res
            }

            // If the resolver couldn't mint a row (DB error path), skip.
            if resolution.speakerID == 0 { continue }

            let currentLabel: String
            if let currentID = candidate.speakerID,
               let label = try? await library.displayLabel(forSpeakerID: currentID) {
                currentLabel = label
            } else {
                currentLabel = "Speaker ?"
            }

            updates.append(SpeakerLibrary.CorrectionUpdate(
                segmentID: candidate.id,
                dateKey: candidate.dateKey,
                startedAt: candidate.startedAt,
                source: candidate.source,
                text: candidate.text,
                oldLabel: currentLabel,
                newSpeakerID: resolution.speakerID,
                newLabel: resolution.displayLabel
            ))
            liveUpdates.append(CorrectionLiveUpdate(
                source: candidate.source == .mic ? .mic : .system,
                startedAt: candidate.startedAt,
                text: candidate.text,
                newSpeakerLabel: resolution.displayLabel,
                newSpeakerID: resolution.speakerID
            ))
        }

        guard !updates.isEmpty else {
            log.info("[\(context.rawValue, privacy: .public)] \(candidates.count) candidates evaluated, no relabels needed")
            return
        }

        // Group by dateKey — usually one day, but a pass that straddles
        // midnight could touch two. Apply each day's batch separately.
        let updatesByDay = Dictionary(grouping: updates, by: { $0.dateKey })
        var totalRelabeled = 0
        for (dateKey, dayUpdates) in updatesByDay {
            do {
                let outcome = try await library.applyCorrections(
                    dayUpdates,
                    dateKey: dateKey,
                    transcriptFolder: await writer.currentFolder(),
                    writer: writer
                )
                totalRelabeled += outcome.relabeledSegmentIDs.count
                log.info("[\(context.rawValue, privacy: .public)] applied corrections: day=\(dateKey, privacy: .public), relabeled rows=\(outcome.relabeledSegmentIDs.count)/\(dayUpdates.count), lines rewritten=\(outcome.relabeledLineCount)")
            } catch {
                log.error("[\(context.rawValue, privacy: .public)] applyCorrections failed for day=\(dateKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await metrics.recordError(.diskWriteFailure)
            }
        }

        // Invalidate resolver cache for every speakerID we touched so the
        // live path picks up the new display labels on the very next
        // utterance.
        let touched = Set(updates.map { $0.newSpeakerID })
        if !touched.isEmpty {
            await resolver.invalidate(speakerIDs: touched)
        }

        // Silent panel update — same `liveUpdates` batch applied across
        // both relabeled and provisional→corrected segments.
        let updatesForPanel = liveUpdates
        await MainActor.run { [liveTranscript] in
            liveTranscript.applyCorrectionUpdates(updatesForPanel)
        }

        if totalRelabeled > 0 {
            await metrics.recordSegmentsRelabeled(count: totalRelabeled)
        }
    }

    /// Overlap-weighted vote: for each offline slot, sum the intersection
    /// of its segments with `span`; the slot with the largest total wins.
    /// Returns nil if no offline segment overlaps the span (rare —
    /// usually means the segment fell into a silence window the offline
    /// pass excluded).
    private func dominantSlot(
        span: (start: TimeInterval, end: TimeInterval),
        segments: [TimedSpeakerSegment]
    ) -> String? {
        var byslot: [String: Double] = [:]
        for seg in segments {
            let lo = max(span.start, TimeInterval(seg.startTimeSeconds))
            let hi = min(span.end, TimeInterval(seg.endTimeSeconds))
            let overlap = max(0, hi - lo)
            if overlap > 0 {
                byslot[seg.speakerId, default: 0] += overlap
            }
        }
        return byslot.max(by: { $0.value < $1.value })?.key
    }
}

/// CP1 — value-type carrier for a snapshot of a pipeline's rolling 5-min
/// correction buffer. Both `MicPipeline` and `SystemAudioPipeline` build
/// one in `correctionAudioSnapshot()`; `CorrectionPass.runPass` consumes
/// them.
///
/// Sendable so it can cross the actor boundary without an explicit copy
/// (the `[Float]` payload IS the copy, which is intentional: we hold the
/// audio just long enough to feed the offline diarizer, then release).
struct CorrectionAudioSnapshot: Sendable {
    let samples: [Float]
    let bufferStart: Date
    let sampleRate: Int
}
