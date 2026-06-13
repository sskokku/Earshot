//
//  MicPipeline.swift
//  EarShot
//

import AVFoundation
import FluidAudio
import Foundation
import os

/// One mic-side pipeline: AVAudioEngine capture → Silero VAD streaming gate →
/// Parakeet TDT v3 ASR. Lives as an actor so all state mutation is serial.
///
/// CLAUDE.md rules respected here:
/// - Rule 1: this is the mic pipeline only. The system-audio pipeline (chunk 2 of
///   Phase 2) is a separate instance; they never mix pre-diarization.
/// - Rule 2: rolling utterance buffer is capped at 30 s. Beyond that we
///   force-finalize, emit, and start a new utterance.
/// - Rule 5: audio is ephemeral. We hold a single growing `[Float]` only for the
///   in-progress utterance and release it the moment ASR finishes.
/// - Rule 6: route changes and engine reconfigurations rebuild silently.
actor MicPipeline {
    // MARK: Public

    /// Updates pushed to the floating panel. Hop to the main actor on the
    /// receive side; do not assume same-actor isolation here.
    ///
    /// `onFinalized` now carries the full S3 payload (segment + embedding +
    /// chunk-local slot label + session id + duration) so the merge layer
    /// can hand it to `IdentityResolver` before the segment hits the panel
    /// or disk. Pre-S3 callers can synthesize a payload with `embedding =
    /// nil` and `slotLabel = ""` — the merge layer skips identity
    /// resolution in that case.
    var onProvisional: (@Sendable (String) -> Void)?
    var onFinalized: (@Sendable (MergeLayer.FinalizedSegment) -> Void)?
    var onStatusChange: (@Sendable (Status) -> Void)?

    enum Status: Equatable {
        case stopped
        case listening
        case paused
        case failed(String)
    }

    private(set) var status: Status = .stopped

    func setHandlers(
        onProvisional: @escaping @Sendable (String) -> Void,
        onFinalized: @escaping @Sendable (MergeLayer.FinalizedSegment) -> Void,
        onStatusChange: @escaping @Sendable (Status) -> Void
    ) {
        self.onProvisional = onProvisional
        self.onFinalized = onFinalized
        self.onStatusChange = onStatusChange
    }

    // MARK: Init

    private let asr: AsrManager
    private let vad: VadManager
    private let log = Logger(subsystem: "com.earshot.app", category: "MicPipeline")

    /// Optional pipe to MetricsCollector. Wired by AppDelegate after init so
    /// the pipeline itself stays constructable without a collector (handy
    /// for tests).
    private var metrics: MetricsCollector?

    /// Streaming diarizer. Optional so the pipeline stays constructable in
    /// tests without one; in production AppDelegate always wires it.
    /// CLAUDE.md rule 3: feeding is fire-and-forget so the diarizer never
    /// blocks the live VAD/ASR loop.
    private var diarizer: DiarizerActor?

    /// Persistent speaker library (S2). Optional for the same reason as
    /// the diarizer above. When wired, every finalized segment with a
    /// resolvable Sortformer label produces one stored embedding.
    private var speakerLibrary: SpeakerLibrary?
    private var embeddingExtractor: EmbeddingExtractor?
    /// Per-pipeline-boot token; fresh UUID on every `start()` so the
    /// library's session map clears across restarts.
    private var sessionToken: SpeakerLibrary.SessionToken?

    init(asr: AsrManager, vad: VadManager) {
        self.asr = asr
        self.vad = vad
    }

    func setMetrics(_ collector: MetricsCollector) {
        self.metrics = collector
    }

    func setDiarizer(_ diarizer: DiarizerActor) {
        self.diarizer = diarizer
    }

    func setSpeakerLibrary(_ library: SpeakerLibrary) {
        self.speakerLibrary = library
    }

    func setEmbeddingExtractor(_ extractor: EmbeddingExtractor) {
        self.embeddingExtractor = extractor
    }

    /// Called by AppDelegate when thermal state crosses into/out of `.serious`.
    /// CLAUDE.md long-run survival §: widen VAD gating under thermal pressure.
    /// We back off provisional ASR cadence — same VAD events still finalize
    /// segments, but mid-utterance retranscribes happen half as often, which
    /// halves ANE work for an in-progress speaker.
    func setThermalPressure(_ high: Bool) {
        provisionalIntervalSamples = high ? Int(3.0 * 16_000) : Int(1.5 * 16_000)
    }

    // MARK: State

    private let engine = AVAudioEngine()
    private var streamContinuation: AsyncStream<[Float]>.Continuation?
    private var consumerTask: Task<Void, Never>?
    private var routeObserver: NSObjectProtocol?
    private var engineConfigObserver: NSObjectProtocol?

    /// Carry between VAD chunks per FluidAudio's streaming API contract.
    private var vadState: VadStreamState?

    /// 256 ms hops at 16 kHz.
    private let vadChunkSize = VadManager.chunkSize  // 4096
    private let sampleRate = VadManager.sampleRate   // 16_000

    /// Leftover samples that did not fill a full VAD chunk last drain.
    private var carry: [Float] = []

    /// Utterance accumulator. Cleared on segment finalize.
    private var utterance: [Float] = []
    private var utteranceStartedAt: Date?

    /// Rolling 30-second cap (rule 2). 30 s * 16 kHz = 480_000 samples.
    private let maxUtteranceSamples = 30 * 16_000

    /// Throttle for provisional ASR. We retranscribe at most every
    /// `provisionalIntervalSamples` worth of fresh audio. Mutable so
    /// `setThermalPressure` can widen it under heat.
    private var provisionalIntervalSamples = Int(1.5 * 16_000)
    private var samplesSinceLastProvisional = 0
    private var provisionalInFlight = false

    /// CP1 — rolling 5-min PCM ring buffer used by the offline correction
    /// pass. CLAUDE.md rule 2 ("rolling 30 s buffer max") gets a deliberate
    /// exception here: PRD R6's offline re-diarization needs audio to work
    /// against, and there is no other source — audio is not persisted to
    /// disk (rule 5). At 16 kHz mono Float32, 5 minutes is ~19 MB per
    /// pipeline, which is fine on the always-on Mac this app targets. The
    /// buffer is anchored to `bufferEpoch`, the wall-clock time of
    /// `correctionBuffer[0]`; oldest samples are trimmed past the cap and
    /// `bufferEpoch` advances accordingly. Cleared on `start()` / pause so
    /// the snapshot never spans a teardown gap.
    private var correctionBuffer: [Float] = []
    private var correctionBufferEpoch: Date?
    private let correctionWindowSamples = Int(CorrectionPass.windowSeconds * 16_000)

    // MARK: Start / stop

    func start() async {
        guard status != .listening else { return }
        // From .paused or .failed we want a clean restart; the only state we
        // skip is already-.listening to keep this call idempotent.

        // Each start is a fresh stream.
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        self.streamContinuation = continuation
        self.vadState = await vad.makeStreamState()
        self.carry.removeAll(keepingCapacity: true)
        self.utterance.removeAll(keepingCapacity: true)
        self.utteranceStartedAt = nil
        self.samplesSinceLastProvisional = 0
        self.provisionalInFlight = false
        self.correctionBuffer.removeAll(keepingCapacity: true)
        self.correctionBufferEpoch = nil

        // Fresh stream session = fresh speaker numbering. Sortformer's slot
        // indices are not portable across reset(), so resetting here keeps the
        // session-local "Speaker N" labels coherent.
        if let diarizer = self.diarizer {
            await diarizer.reset()
        }

        // Mint a fresh speaker-library session so "Speaker N" → persistent
        // speaker id mappings start clean. Old token is dropped on the floor;
        // any embeddings written under it are still in the DB.
        if let library = self.speakerLibrary {
            self.sessionToken = await library.newSession()
        }

        do {
            try installTapAndStart()
        } catch {
            log.error("Engine start failed: \(error.localizedDescription, privacy: .public)")
            // Engine-start failure shares a surface with route changes
            // (AVAudioEngine's input graph can't be set up). Bucket it there
            // rather than extend the taxonomy.
            await metrics?.recordError(.routeChange)
            setStatus(.failed("Could not start the mic engine: \(error.localizedDescription)"))
            continuation.finish()
            self.streamContinuation = nil
            return
        }

        installRouteObservers()

        consumerTask = Task { [weak self] in
            guard let self else { return }
            await self.consume(stream: stream)
        }

        setStatus(.listening)
    }

    func stop() async {
        guard status == .listening || status == .paused else { return }
        await teardownPipeline()
        setStatus(.stopped)
    }

    /// Tear down the engine, identical to `stop()` mechanically, but the
    /// surfaced status is `.paused` so the menu bar glyph distinguishes a
    /// user-initiated halt from a clean stop. Resume with `resume()`.
    func pause() async {
        guard status == .listening else { return }
        await teardownPipeline()
        setStatus(.paused)
    }

    func resume() async {
        guard status == .paused else { return }
        await start()
    }

    private func teardownPipeline() async {
        streamContinuation?.finish()
        streamContinuation = nil
        consumerTask?.cancel()
        consumerTask = nil
        teardownEngine()
        removeRouteObservers()
        carry.removeAll(keepingCapacity: false)
        utterance.removeAll(keepingCapacity: false)
        utteranceStartedAt = nil
        samplesSinceLastProvisional = 0
        provisionalInFlight = false
        correctionBuffer.removeAll(keepingCapacity: false)
        correctionBufferEpoch = nil
    }

    // MARK: Engine

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // EnrollmentRecorder's converter is single-shot; the live tap fires on a
        // background thread tens of times per second, so we keep a Sendable box
        // that owns the converter and emits resampled chunks into the stream.
        let pump = SamplePump(continuation: streamContinuation)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            pump.ingest(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    private func teardownEngine() {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func installRouteObservers() {
        // AVAudioEngineConfigurationChange fires when the hardware route shifts
        // under us (AirPods connecting, device switch). The engine's graph is
        // invalid after; the safest recovery is a tear-down + restart.
        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.handleEngineReconfigure()
            }
        }
    }

    private func removeRouteObservers() {
        if let token = engineConfigObserver {
            NotificationCenter.default.removeObserver(token)
        }
        engineConfigObserver = nil
        if let token = routeObserver {
            NotificationCenter.default.removeObserver(token)
        }
        routeObserver = nil
    }

    private func handleEngineReconfigure() async {
        log.info("AVAudioEngineConfigurationChange; rebuilding mic graph")
        // CLAUDE.md error taxonomy: route change is a first-class class. The
        // rebuild that follows is the recovery, counted regardless of outcome.
        await metrics?.recordError(.routeChange)
        await metrics?.recordRecoveryAttempt(.routeChange)

        teardownEngine()
        carry.removeAll(keepingCapacity: true)
        do {
            try installTapAndStart()
            // Rule 6: recover loud-free. If the rebuild succeeded, we stay
            // .listening; the engine started clean. No glyph change, no log
            // line beyond debug.
        } catch {
            log.error("Engine restart failed: \(error.localizedDescription, privacy: .public)")
            setStatus(.failed("Mic engine could not restart: \(error.localizedDescription)"))
        }
    }

    // MARK: Consumer loop

    private func consume(stream: AsyncStream<[Float]>) async {
        for await samples in stream {
            await processIncoming(samples)
        }
    }

    private func processIncoming(_ samples: [Float]) async {
        appendToCorrectionBuffer(samples)
        carry.append(contentsOf: samples)

        while carry.count >= vadChunkSize {
            let chunk = Array(carry.prefix(vadChunkSize))
            carry.removeFirst(vadChunkSize)
            await processVadChunk(chunk)
        }
    }

    /// Append PCM samples to the rolling 5-min correction buffer, trimming
    /// the oldest samples once we exceed the window and advancing
    /// `correctionBufferEpoch` accordingly. Anchored to wall-clock
    /// `Date()` minus the chunk's duration so the slice math in
    /// `CorrectionPass` lines up with the segment timestamps stored in
    /// the segments table.
    private func appendToCorrectionBuffer(_ samples: [Float]) {
        if samples.isEmpty { return }
        let chunkDuration = Double(samples.count) / Double(sampleRate)
        let now = Date()
        if correctionBufferEpoch == nil {
            correctionBufferEpoch = now.addingTimeInterval(-chunkDuration)
        }
        correctionBuffer.append(contentsOf: samples)
        let overflow = correctionBuffer.count - correctionWindowSamples
        if overflow > 0 {
            correctionBuffer.removeFirst(overflow)
            let advance = Double(overflow) / Double(sampleRate)
            correctionBufferEpoch = correctionBufferEpoch?.addingTimeInterval(advance)
        }
    }

    /// CP1 — snapshot of the rolling 5-min correction buffer. Returns nil
    /// while the pipeline hasn't received any audio yet (just started, or
    /// post-pause before the first chunk arrives). Caller is the
    /// `CorrectionPass` actor, which feeds the samples into
    /// `DiarizerManager.performCompleteDiarization` for offline
    /// re-attribution.
    func correctionAudioSnapshot() -> CorrectionAudioSnapshot? {
        guard let epoch = correctionBufferEpoch, !correctionBuffer.isEmpty else { return nil }
        return CorrectionAudioSnapshot(
            samples: correctionBuffer,
            bufferStart: epoch,
            sampleRate: sampleRate
        )
    }

    private func processVadChunk(_ chunk: [Float]) async {
        guard let state = vadState else { return }

        // Forward the chunk to the diarizer fire-and-forget. The chunk is
        // ~256 ms of speech; the timestamp we report is the wall-clock moment
        // its earliest sample arrived (now − chunkDuration), which keeps the
        // diarizer's epoch-relative clock in sync with utterance timestamps.
        if let diarizer = self.diarizer {
            let chunkDuration = Double(chunk.count) / Double(sampleRate)
            let capturedAt = Date().addingTimeInterval(-chunkDuration)
            Task { await diarizer.feed(chunk, capturedAt: capturedAt) }
        }

        let result: VadStreamResult
        do {
            result = try await vad.processStreamingChunk(
                chunk,
                state: state,
                config: .default,
                returnSeconds: true,
                timeResolution: 2
            )
        } catch {
            log.error("VAD chunk failed: \(error.localizedDescription, privacy: .public)")
            // VAD is the front end of the recognition pipeline; fold its
            // failures into asrFailure rather than extend the enum. CLAUDE.md
            // taxonomy is intentionally tight (six classes), and VAD failure
            // is functionally indistinguishable from "speech recognition
            // pipeline could not advance".
            await metrics?.recordError(.asrFailure)
            return
        }
        vadState = result.state

        if let event = result.event {
            switch event.kind {
            case .speechStart:
                handleSpeechStart()
            case .speechEnd:
                await handleSpeechEnd()
            }
        }

        // Accumulate any audio that lies inside an active utterance. Note: even
        // before the very first speechStart, the VAD's hysteresis may already
        // be tracking pre-roll. We start accumulating only after speechStart
        // is observed, which is the contract that keeps the 30 s cap meaningful.
        if utteranceStartedAt != nil {
            utterance.append(contentsOf: chunk)
            samplesSinceLastProvisional += chunk.count

            if utterance.count >= maxUtteranceSamples {
                log.info("Utterance hit 30 s cap; force-finalizing")
                await finalizeCurrent(forcedByCap: true)
                return
            }

            if !provisionalInFlight && samplesSinceLastProvisional >= provisionalIntervalSamples {
                samplesSinceLastProvisional = 0
                await runProvisionalTranscribe()
            }
        }
    }

    private func handleSpeechStart() {
        guard utteranceStartedAt == nil else { return }
        utteranceStartedAt = Date()
        utterance.removeAll(keepingCapacity: true)
        samplesSinceLastProvisional = 0
    }

    private func handleSpeechEnd() async {
        guard utteranceStartedAt != nil else { return }
        await finalizeCurrent(forcedByCap: false)
    }

    // MARK: ASR

    private func runProvisionalTranscribe() async {
        guard !utterance.isEmpty else { return }
        provisionalInFlight = true
        let snapshot = utterance  // copy on write
        let handler = onProvisional
        do {
            // Each transcribe call is stateless per-chunk per FluidAudio's docs;
            // we hand it a fresh decoder state every time.
            var decoderState = TdtDecoderState.make()
            let result = try await asr.transcribe(snapshot, decoderState: &decoderState)
            let text = result.text
            if !text.isEmpty, let handler {
                handler(text)
            }
        } catch {
            log.error("Provisional ASR failed: \(error.localizedDescription, privacy: .public)")
            await metrics?.recordError(.asrFailure)
        }
        provisionalInFlight = false
    }

    private func finalizeCurrent(forcedByCap: Bool) async {
        guard let startedAt = utteranceStartedAt, !utterance.isEmpty else {
            utteranceStartedAt = nil
            utterance.removeAll(keepingCapacity: true)
            samplesSinceLastProvisional = 0
            return
        }

        let snapshot = utterance
        let endedAt = Date()
        utterance.removeAll(keepingCapacity: true)
        utteranceStartedAt = nil
        samplesSinceLastProvisional = 0

        // Speech-seconds bucket regardless of whether ASR produced text — VAD
        // already decided this was speech, so it counts toward listening-vs-
        // silence even if Parakeet whiffed.
        await metrics?.recordSpeech(pipeline: .mic, seconds: endedAt.timeIntervalSince(startedAt))

        do {
            var decoderState = TdtDecoderState.make()
            let result = try await asr.transcribe(snapshot, decoderState: &decoderState)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            // Resolve the dominant speaker for the utterance window. Result is
            // provisional per CLAUDE.md rule 3 — Phase 4's correction pass will
            // rewrite labels if the offline diarizer disagrees. The label
            // here is the chunk-local Sortformer slot label (e.g. "Speaker 1")
            // and is rewritten to a persistent identity by `IdentityResolver`
            // inside the merge layer (rule 8).
            let slotLabel = await diarizer?.label(forStart: startedAt, end: endedAt)
            let segment = LiveTranscript.Segment(
                id: UUID(),
                startedAt: startedAt,
                endedAt: endedAt,
                source: .mic,
                speakerLabel: slotLabel,
                text: text
            )
            await metrics?.recordSegment(pipeline: .mic, text: text)

            // S3: extract the embedding and emit a FinalizedSegment payload.
            // Embedding extraction runs in a detached Task so the next VAD
            // chunk arriving on the consumer loop isn't blocked by WeSpeaker
            // inference. The snapshot is pinned inside the Task closure so
            // the buffer survives the utterance reset above. The merge
            // layer's resolver rewrites the segment's `speakerLabel` to a
            // persistent display label before forwarding to panel + disk.
            let extractor = self.embeddingExtractor
            let token = self.sessionToken
            let handler = self.onFinalized
            let durationSeconds = endedAt.timeIntervalSince(startedAt)
            let resolvedSlot = slotLabel ?? ""
            Task {
                let vector: [Float]?
                if let extractor {
                    vector = await extractor.extract(samples: snapshot)
                } else {
                    vector = nil
                }
                let payload = MergeLayer.FinalizedSegment(
                    segment: segment,
                    embedding: vector,
                    slotLabel: resolvedSlot,
                    sessionID: token?.id ?? UUID(),
                    durationSeconds: durationSeconds
                )
                handler?(payload)
            }
        } catch {
            log.error("Final ASR failed: \(error.localizedDescription, privacy: .public)")
            await metrics?.recordError(.asrFailure)
        }

        if forcedByCap {
            // Treat the immediate next audio as a fresh utterance start, since
            // the speaker is presumably still talking.
            utteranceStartedAt = Date()
        }
    }

    // MARK: Status

    private func setStatus(_ next: Status) {
        status = next
        onStatusChange?(next)
    }

    // MARK: H1 — debug surfaces

    /// H1 — soak-mode entry point. Pushes synthetic samples directly into
    /// the consumer loop's AsyncStream as if the AVAudioEngine tap had
    /// produced them, bypassing the audio device. Only `SoakHarness`
    /// (gated by `AppSettings.soakModeEnabled`) calls this. No-op if the
    /// pipeline is not currently `.listening`.
    func injectSoakAudio(_ samples: [Float]) {
        guard status == .listening else { return }
        streamContinuation?.yield(samples)
    }

    /// H1 — route-change torture surface. Drives the same path the
    /// `AVAudioEngineConfigurationChange` notification triggers. Used by
    /// the unit test to verify repeated reconfigures are safe (no
    /// permanent state growth, no crash, status returns to a known
    /// terminal value). Production code reaches this path via the
    /// notification observer; tests reach it here.
    func debugTriggerRouteChange() async {
        await handleEngineReconfigure()
    }

    /// H1 — test-only carry-buffer inspector. Used by the torture test to
    /// assert no per-reconfigure growth. `carry` is the pre-VAD residue
    /// from the last drain; on reconfigure it must be cleared.
    func debugCarryCount() -> Int { carry.count }

}

/// Bridges the AVAudioEngine tap (background thread, no Swift Concurrency) to
/// our async pipeline. Holds the non-Sendable `AudioConverter` behind a lock so
/// the tap callback never reaches into actor-isolated state directly.
private final class SamplePump: @unchecked Sendable {
    private let lock = NSLock()
    private let converter = AudioConverter()
    private let continuation: AsyncStream<[Float]>.Continuation?

    nonisolated init(continuation: AsyncStream<[Float]>.Continuation?) {
        self.continuation = continuation
    }

    nonisolated func ingest(_ buffer: AVAudioPCMBuffer) {
        let resampled: [Float]?
        lock.lock()
        resampled = try? converter.resampleBuffer(buffer)
        lock.unlock()
        guard let samples = resampled, !samples.isEmpty else { return }
        continuation?.yield(samples)
    }
}
