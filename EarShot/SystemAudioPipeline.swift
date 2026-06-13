//
//  SystemAudioPipeline.swift
//  EarShot
//

import AVFoundation
import AppKit
import CoreAudio
import FluidAudio
import Foundation
import os

/// Phase 2 / Chunk C1 — system-audio counterpart to `MicPipeline`.
///
/// Captures per-process output via a macOS 14.4+ Core Audio process tap
/// (`CATapDescription` + `AudioHardwareCreateProcessTap` + aggregate device IO
/// proc), runs the same Silero VAD streaming gate and Parakeet TDT v3 ASR as
/// the mic side, and pushes finalized segments tagged `.system`.
///
/// CLAUDE.md rules respected:
/// - Rule 1: independent capture, independent VAD/ASR/diarizer instances.
///   Nothing here touches mic state.
/// - Rule 2: 30 s utterance cap; rolling carry buffer; no permanent growth.
/// - Rule 5: audio is ephemeral. Only the in-flight utterance is held.
/// - Rule 6: tap detach / format change rebuild silently and bucket as
///   `routeChange` / `tapDetach`.
/// - Rule 9: local-only. No network calls.
///
/// Acceptance failure C1 ("Teams call: zero system segments") was tracked to
/// three plausible suspects in PROGRESS.md. The instrumentation in here is
/// laid out so the first 60 s of a live call surfaces which suspect bit:
///   1. Bundle ID. `enumerateHALProcesses()` logs every process the audio HAL
///      knows about with its PID + bundle ID. Allowlist match/miss is logged
///      per process so a typo (com.microsoft.teams vs com.microsoft.teams2)
///      shows up immediately.
///   2. Permission. The OS log line "About to create process tap …" is
///      emitted immediately before `AudioHardwareCreateProcessTap`. If the
///      next log line is a non-zero OSStatus or a stall, the TCC prompt did
///      not fire / was denied; the `NSAudioCaptureUsageDescription`
///      Info.plist key + the sandbox entitlement are the suspects.
///   3. Wrong PID (parent vs helper). We enumerate the HAL's process list
///      rather than `NSWorkspace.runningApplications` precisely because the
///      HAL surfaces helper processes that have actually opened audio. The
///      logged PID is the one the tap will attach to. If audio plays but the
///      callback counter (every 10 s) stays at 0, the wrong process object
///      is targeted.
actor SystemAudioPipeline {

    // MARK: Public types

    enum Status: Equatable {
        case stopped
        /// Capture is up; no allow-listed app is producing audio yet. Polling
        /// continues every `targetPollSeconds`.
        case waitingForTarget
        case listening
        case paused
        case failed(String)
    }

    /// Default Phase 2 allowlist. Phase 2 / C2 adds the UI to edit this.
    ///
    /// Why this is structured instead of a flat `Set<String>`: live runtime
    /// logging on a Teams2 install (see PROGRESS.md "Chunk C1") showed the
    /// HAL surfaces audio under HELPER bundle IDs, not the parent app's:
    /// `com.microsoft.teams2.notification`,
    /// `com.microsoft.teams2.notificationcenter`, and the system WebKit GPU
    /// helper that's named "Microsoft Teams Graphics and Media" with bundle
    /// `com.microsoft.WebKit.GPU`. An exact-match allowlist whiffs on every
    /// one of those. So the matcher does:
    ///   1. `bundleIDPrefixes` — exact or `prefix + "."` (catches all Teams2
    ///      and Zoom XOS helpers without also matching unrelated apps).
    ///   2. `nameContains` — case-insensitive substring against
    ///      `NSRunningApplication.localizedName` (catches the WebKit GPU
    ///      helper whose bundle ID is generic but whose process name carries
    ///      the parent app's brand).
    /// Either match qualifies.
    struct AllowlistEntry: Sendable {
        let bundleIDPrefixes: [String]
        let nameContains: [String]
        let displayName: String
        /// Legacy / dead variant — still matched so the log can flag it, but
        /// the tap skips it because no audio will ever flow.
        let isLegacy: Bool
    }

    /// Phase 2 / C2 made the allowlist user-editable. The default provider
    /// reads from `SystemAudioAllowlist`, which seeds Teams (new) and Zoom
    /// on first launch to preserve C1's hard-coded behavior. Tests can
    /// inject their own provider closure.
    static func defaultAllowlistProvider() -> @Sendable () -> [AllowlistEntry] {
        { SystemAudioAllowlist.currentEntries() }
    }

    enum MatchReason: CustomStringConvertible {
        case exactBundle(String)
        case prefixBundle(String)
        case nameContains(String)

        var description: String {
            switch self {
            case .exactBundle(let s):  return "exact bundle '\(s)'"
            case .prefixBundle(let s): return "prefix bundle '\(s).*'"
            case .nameContains(let s): return "name contains '\(s)'"
            }
        }
    }

    // MARK: Handlers (mirrors MicPipeline)

    var onProvisional: (@Sendable (String) -> Void)?
    /// S3: payload-style handler. See `MicPipeline.onFinalized` for the
    /// rationale — embedding + slot label + session id travel with the
    /// segment so the merge layer's `IdentityResolver` can rewrite the
    /// speaker label to a persistent identity (rule 8).
    var onFinalized: (@Sendable (MergeLayer.FinalizedSegment) -> Void)?
    var onStatusChange: (@Sendable (Status) -> Void)?

    func setHandlers(
        onProvisional: @escaping @Sendable (String) -> Void,
        onFinalized: @escaping @Sendable (MergeLayer.FinalizedSegment) -> Void,
        onStatusChange: @escaping @Sendable (Status) -> Void
    ) {
        self.onProvisional = onProvisional
        self.onFinalized = onFinalized
        self.onStatusChange = onStatusChange
    }

    private(set) var status: Status = .stopped

    // MARK: Dependencies

    private let asr: AsrManager
    private let vad: VadManager
    private let allowlistProvider: @Sendable () -> [AllowlistEntry]
    private let log = Logger(subsystem: "com.earshot.app", category: "SystemAudioPipeline")
    private var metrics: MetricsCollector?
    private var diarizer: DiarizerActor?

    /// S2 — persistent speaker library + embedding extractor. Same wiring
    /// pattern as MicPipeline; the per-pipeline session token isolates the
    /// system slot→speaker map from the mic side so a "Speaker 1" on mic
    /// and a "Speaker 1" on system map to different persistent rows (rule 1).
    private var speakerLibrary: SpeakerLibrary?
    private var embeddingExtractor: EmbeddingExtractor?
    private var sessionToken: SpeakerLibrary.SessionToken?

    init(
        asr: AsrManager,
        vad: VadManager,
        allowlistProvider: @escaping @Sendable () -> [AllowlistEntry] = SystemAudioPipeline.defaultAllowlistProvider()
    ) {
        self.asr = asr
        self.vad = vad
        self.allowlistProvider = allowlistProvider
    }

    /// Returns the first allowlist entry that matches, along with the reason
    /// (exact / prefix / name). nil if no entry matches.
    private func matchAllowlist(entries: [AllowlistEntry], bundleID: String?, appName: String?) -> (AllowlistEntry, MatchReason)? {
        for entry in entries {
            if let bid = bundleID {
                for prefix in entry.bundleIDPrefixes {
                    if bid == prefix {
                        return (entry, .exactBundle(prefix))
                    }
                    if bid.hasPrefix(prefix + ".") {
                        return (entry, .prefixBundle(prefix))
                    }
                }
            }
            if let name = appName?.lowercased() {
                for needle in entry.nameContains {
                    if name.contains(needle) {
                        return (entry, .nameContains(needle))
                    }
                }
            }
        }
        return nil
    }

    func setMetrics(_ collector: MetricsCollector) { self.metrics = collector }
    func setDiarizer(_ d: DiarizerActor) { self.diarizer = d }
    func setSpeakerLibrary(_ library: SpeakerLibrary) { self.speakerLibrary = library }
    func setEmbeddingExtractor(_ extractor: EmbeddingExtractor) { self.embeddingExtractor = extractor }

    /// CLAUDE.md long-run survival §: widen VAD throttle under thermal pressure.
    /// Mirrors `MicPipeline.setThermalPressure`.
    func setThermalPressure(_ high: Bool) {
        provisionalIntervalSamples = high ? Int(3.0 * 16_000) : Int(1.5 * 16_000)
    }

    // MARK: VAD / ASR state (mirrors MicPipeline)

    private var streamContinuation: AsyncStream<[Float]>.Continuation?
    private var consumerTask: Task<Void, Never>?
    private var vadState: VadStreamState?
    private let vadChunkSize = VadManager.chunkSize   // 4096
    private let sampleRate = VadManager.sampleRate    // 16_000
    private var carry: [Float] = []
    private var utterance: [Float] = []
    private var utteranceStartedAt: Date?
    private let maxUtteranceSamples = 30 * 16_000
    private var provisionalIntervalSamples = Int(1.5 * 16_000)
    private var samplesSinceLastProvisional = 0
    private var provisionalInFlight = false

    /// CP1 — rolling 5-min PCM ring buffer for the offline correction
    /// pass. See `MicPipeline.correctionBuffer` for the rationale (rule 2
    /// gets a deliberate exception so Phase 4's offline re-diarization can
    /// run without persisting audio to disk).
    private var correctionBuffer: [Float] = []
    private var correctionBufferEpoch: Date?
    private let correctionWindowSamples = Int(CorrectionPass.windowSeconds * 16_000)

    // MARK: Tap state + instrumentation

    /// Owns the CoreAudio tap, aggregate device, and IO proc. nil while no
    /// allowed app has been found yet.
    private var tap: ProcessTap?
    /// All PIDs the current tap targets. The HAL surfaces Teams audio under
    /// helper bundle IDs (`com.microsoft.teams2.notification`,
    /// `com.microsoft.WebKit.GPU` named "Microsoft Teams Graphics and Media",
    /// etc.) so we attach the tap to every audio-running helper at once.
    private var attachedPIDs: [pid_t] = []
    private var attachedDescription: String = ""

    /// Background poller for target apps. Lets a meeting that starts mid-day
    /// auto-attach without a manual restart.
    private var pollTask: Task<Void, Never>?
    private let targetPollSeconds: UInt64 = 5

    /// Instrumentation: callback counter sweep every 10 s. CLAUDE.md "Things
    /// already learned" — a silent tap is the failure mode that bit us in C1,
    /// so the counter is built in from the start.
    private var instrumentationTask: Task<Void, Never>?
    private let callbackCounter = AtomicCounter()
    private var lastReportedCallbackCount: Int = 0

    /// Set true after the FIRST IOProc callback so we only log the format
    /// once per tap session.
    private var firstFrameFormatLogged = false

    /// Observes `SystemAudioAllowlist.allowlistChangedNotification`. When
    /// the user flips a toggle in Settings we re-evaluate the tap target
    /// immediately so a meeting in progress switches off mid-call.
    private var allowlistObserverTask: Task<Void, Never>?

    // MARK: Lifecycle

    func start() async {
        guard status != .listening else { return }
        // Fresh stream every start (mirrors MicPipeline).
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
        self.firstFrameFormatLogged = false
        self.callbackCounter.reset()
        self.lastReportedCallbackCount = 0

        if let d = self.diarizer { await d.reset() }

        // Fresh speaker-library session token per pipeline boot — same
        // logic as MicPipeline.start.
        if let library = self.speakerLibrary {
            self.sessionToken = await library.newSession()
        }

        consumerTask = Task { [weak self] in
            guard let self else { return }
            await self.consume(stream: stream)
        }

        let initialEntries = allowlistProvider()
        let allowlistDescription = initialEntries
            .map { "\($0.displayName)\($0.isLegacy ? " [legacy, never attached]" : "")" }
            .joined(separator: " | ")
        log.info("System audio pipeline starting. Allowlist (\(initialEntries.count) entries): \(allowlistDescription, privacy: .public)")

        // Try once now. If no target, drop to .waitingForTarget and let the
        // poll task keep retrying every 5 s.
        await tryAttachLatestTarget(reason: "initial start")

        startInstrumentationTask()
        startPollingTask()
        startAllowlistObserver()
    }

    func stop() async {
        guard status != .stopped else { return }
        await teardown()
        setStatus(.stopped)
    }

    func pause() async {
        guard status == .listening || status == .waitingForTarget else { return }
        await teardown()
        setStatus(.paused)
    }

    func resume() async {
        guard status == .paused else { return }
        await start()
    }

    private func teardown() async {
        streamContinuation?.finish()
        streamContinuation = nil
        consumerTask?.cancel()
        consumerTask = nil

        instrumentationTask?.cancel()
        instrumentationTask = nil
        pollTask?.cancel()
        pollTask = nil
        allowlistObserverTask?.cancel()
        allowlistObserverTask = nil

        if let existing = tap {
            log.info("Detaching system tap (\(self.attachedDescription, privacy: .public))")
            existing.invalidate()
        }
        tap = nil
        attachedPIDs = []
        attachedDescription = ""
        firstFrameFormatLogged = false

        carry.removeAll(keepingCapacity: false)
        utterance.removeAll(keepingCapacity: false)
        utteranceStartedAt = nil
        samplesSinceLastProvisional = 0
        provisionalInFlight = false
        correctionBuffer.removeAll(keepingCapacity: false)
        correctionBufferEpoch = nil
    }

    // MARK: Target discovery + attach

    /// Enumerates HAL audio processes, matches against the current allowlist
    /// (exact bundle, prefix bundle, or NSRunningApplication name), and taps
    /// every audio-running candidate at once. If a tap is already attached
    /// and the candidate set has not changed, this is a no-op. If the
    /// candidate set changes (user toggled an app on/off in Settings, or a
    /// new meeting helper started producing audio), the existing tap is
    /// detached and a fresh one is attached.
    ///
    /// CLAUDE.md "Things already learned" — a silent tap on the wrong PID
    /// was Suspect 3 in the C1 known-issues entry. Targeting every matching
    /// PID at once means whichever Electron helper is actually producing
    /// call audio is in the tap by construction.
    private func tryAttachLatestTarget(reason: String) async {
        let entries = allowlistProvider()
        let processes = HALAudioProcessLister.enumerate()
        log.info("HAL process enumeration (\(reason, privacy: .public)): \(processes.count) audio-touching processes against \(entries.count) allow-listed entries")

        var candidates: [(HALAudioProcess, AllowlistEntry, MatchReason)] = []
        for proc in processes {
            let bid = proc.bundleID ?? "(no bundle id)"
            let appName = NSRunningApplication(processIdentifier: proc.pid)?.localizedName ?? "?"
            let runningTag = proc.isRunning ? "running" : "idle"
            if let (entry, why) = matchAllowlist(entries: entries, bundleID: proc.bundleID, appName: appName) {
                let legacyTag = entry.isLegacy ? " [LEGACY, will not attach]" : ""
                log.info("  MATCH (\(why.description, privacy: .public)) pid=\(proc.pid) bundle=\(bid, privacy: .public) name=\(appName, privacy: .public) [\(runningTag, privacy: .public)] objectID=\(proc.objectID) → \(entry.displayName, privacy: .public)\(legacyTag, privacy: .public)")
                if proc.isRunning && !entry.isLegacy {
                    candidates.append((proc, entry, why))
                }
            } else {
                log.debug("  miss  pid=\(proc.pid) bundle=\(bid, privacy: .public) name=\(appName, privacy: .public) [\(runningTag, privacy: .public)] objectID=\(proc.objectID)")
            }
        }

        let newPIDSet = Set(candidates.map(\.0.pid))

        // Currently attached path: detach if the candidate set has changed.
        // Equal sets → keep current tap, do nothing. Empty new set → detach
        // and wait. Changed non-empty set → tear down and reattach.
        if tap != nil {
            let currentPIDSet = Set(attachedPIDs)
            if newPIDSet == currentPIDSet {
                return
            }
            log.info("Candidate set changed (was \(currentPIDSet.sorted()), now \(newPIDSet.sorted())); detaching to reattach")
            detachTap()
            setStatus(.waitingForTarget)
        }

        guard !candidates.isEmpty else {
            if status != .waitingForTarget {
                setStatus(.waitingForTarget)
                log.info("No allow-listed audio-producing process found; waiting.")
            }
            return
        }

        let objectIDs = candidates.map(\.0.objectID)
        let pids = candidates.map(\.0.pid)
        let summary = candidates.map { "pid=\($0.0.pid) bundle=\($0.0.bundleID ?? "?")" }
            .joined(separator: ", ")
        log.info("Selected \(candidates.count) targets: \(summary, privacy: .public)")
        log.info("About to create process tap. If NSAudioCaptureUsageDescription is set and TCC has not been granted, the system permission prompt should appear immediately after this line.")

        do {
            let tapHandle = try ProcessTap.attach(
                targetObjectIDs: objectIDs,
                description: summary,
                log: log,
                onSamples: { [weak self] samples in
                    // Hop into the actor; the IOProc fires on Core Audio's
                    // real-time thread which is the wrong place to do work.
                    Task { [weak self] in
                        await self?.ingestSamples(samples)
                    }
                },
                onCallback: { [weak self] in
                    self?.callbackCounter.increment()
                },
                onFormat: { [weak self] sr, ch in
                    Task { [weak self] in
                        await self?.logFirstFrameFormatIfNeeded(sampleRate: sr, channels: ch)
                    }
                },
                onDetach: { [weak self] reason in
                    Task { [weak self] in
                        await self?.handleTapDetached(reason: reason)
                    }
                }
            )
            self.tap = tapHandle
            self.attachedPIDs = pids
            self.attachedDescription = summary
            setStatus(.listening)
            log.info("Tap attached. \(summary, privacy: .public)")
        } catch {
            log.error("Tap attach FAILED for [\(summary, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
            await metrics?.recordError(.tapDetach)
            setStatus(.waitingForTarget)
        }
    }

    private func handleTapDetached(reason: String) async {
        log.info("Tap detached (\(reason, privacy: .public)). \(self.attachedDescription, privacy: .public)")
        await metrics?.recordError(.tapDetach)
        await metrics?.recordRecoveryAttempt(.tapDetach)
        detachTap()
        // Demote status so the poll task tries again on its next tick.
        setStatus(.waitingForTarget)
    }

    /// Tear down the current tap + aggregate device without changing status.
    /// Caller is responsible for any subsequent `setStatus(...)` call.
    private func detachTap() {
        if let existing = tap {
            existing.invalidate()
        }
        tap = nil
        attachedPIDs = []
        attachedDescription = ""
        firstFrameFormatLogged = false
    }

    private func logFirstFrameFormatIfNeeded(sampleRate: Double, channels: UInt32) {
        guard !firstFrameFormatLogged else { return }
        firstFrameFormatLogged = true
        log.info("First system-tap audio frame: rate=\(sampleRate) channels=\(channels). Converting to 16 kHz mono Float32 for VAD/ASR.")
    }

    // MARK: Background tasks

    private func startInstrumentationTask() {
        instrumentationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                await self.reportCallbackRate()
            }
        }
    }

    private func reportCallbackRate() {
        let current = callbackCounter.value
        let delta = current - lastReportedCallbackCount
        lastReportedCallbackCount = current
        let tapTag = attachedDescription.isEmpty ? "no-tap" : attachedDescription
        log.info("System tap callback rate (last 10 s): \(delta) callbacks [\(tapTag, privacy: .public)]")
    }

    private func startPollingTask() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                await self.tryAttachLatestTarget(reason: "periodic poll")
            }
        }
    }

    /// Watch for allowlist edits from Settings and re-evaluate the tap
    /// target on every change. This is how a meeting-in-progress detaches
    /// the moment the user toggles its app off.
    private func startAllowlistObserver() {
        allowlistObserverTask = Task { [weak self] in
            let stream = NotificationCenter.default.notifications(named: SystemAudioAllowlist.allowlistChangedNotification)
            for await _ in stream {
                guard let self else { return }
                await self.tryAttachLatestTarget(reason: "allowlist changed")
            }
        }
    }

    // MARK: Sample ingestion (mirrors MicPipeline.consume)

    private func consume(stream: AsyncStream<[Float]>) async {
        for await samples in stream {
            await processIncoming(samples)
        }
    }

    private func ingestSamples(_ samples: [Float]) async {
        streamContinuation?.yield(samples)
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

    /// See `MicPipeline.appendToCorrectionBuffer` — same anchoring logic
    /// so the buffer's start time stays in sync with the segments table's
    /// wall-clock timestamps.
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

    /// CP1 — snapshot of the rolling 5-min correction buffer.
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
            log.error("System VAD chunk failed: \(error.localizedDescription, privacy: .public)")
            await metrics?.recordError(.asrFailure)
            return
        }
        vadState = result.state

        if let event = result.event {
            switch event.kind {
            case .speechStart: handleSpeechStart()
            case .speechEnd: await handleSpeechEnd()
            }
        }

        if utteranceStartedAt != nil {
            utterance.append(contentsOf: chunk)
            samplesSinceLastProvisional += chunk.count
            if utterance.count >= maxUtteranceSamples {
                log.info("System utterance hit 30 s cap; force-finalizing")
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

    private func runProvisionalTranscribe() async {
        guard !utterance.isEmpty else { return }
        provisionalInFlight = true
        let snapshot = utterance
        let handler = onProvisional
        do {
            var decoderState = TdtDecoderState.make()
            let result = try await asr.transcribe(snapshot, decoderState: &decoderState)
            let text = result.text
            if !text.isEmpty, let handler {
                handler(text)
            }
        } catch {
            log.error("System provisional ASR failed: \(error.localizedDescription, privacy: .public)")
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

        await metrics?.recordSpeech(pipeline: .system, seconds: endedAt.timeIntervalSince(startedAt))

        do {
            var decoderState = TdtDecoderState.make()
            let result = try await asr.transcribe(snapshot, decoderState: &decoderState)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let slotLabel = await diarizer?.label(forStart: startedAt, end: endedAt)
            let segment = LiveTranscript.Segment(
                id: UUID(),
                startedAt: startedAt,
                endedAt: endedAt,
                source: .system,
                speakerLabel: slotLabel,
                text: text
            )
            await metrics?.recordSegment(pipeline: .system, text: text)

            // S3: extract embedding + emit FinalizedSegment so the merge
            // layer's resolver can rewrite the speaker label to a
            // persistent identity. Same off-actor Task pattern as
            // MicPipeline — the next VAD chunk does not wait on WeSpeaker.
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
            log.error("System final ASR failed: \(error.localizedDescription, privacy: .public)")
            await metrics?.recordError(.asrFailure)
        }

        if forcedByCap { utteranceStartedAt = Date() }
    }

    // MARK: Status

    private func setStatus(_ next: Status) {
        guard status != next else { return }
        status = next
        onStatusChange?(next)
    }

    // MARK: H1 — debug surfaces

    /// H1 — soak-mode entry point. See `MicPipeline.injectSoakAudio`.
    /// The system pipeline accepts synthetic audio in any non-stopped
    /// state because it can be `.waitingForTarget` when no Teams/Zoom
    /// call is active — soak mode bypasses target attachment entirely.
    func injectSoakAudio(_ samples: [Float]) {
        guard status != .stopped, status != .paused else { return }
        streamContinuation?.yield(samples)
    }
}

// MARK: - HAL audio-process enumeration

/// One row from `kAudioHardwarePropertyProcessObjectList`.
nonisolated struct HALAudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    /// `kAudioProcessPropertyIsRunning` — true when the process is currently
    /// running an audio IO procedure. This is what we filter on so that
    /// idle apps (Teams sitting in the background) don't get tapped until
    /// the user actually joins a call.
    let isRunning: Bool
}

nonisolated enum HALAudioProcessLister {
    /// Returns every process the audio HAL currently knows about. Unlike
    /// `NSWorkspace.runningApplications`, this surfaces helper / renderer
    /// processes that have actually opened audio — which is the right
    /// universe for tap targeting on Electron apps like new Teams.
    static func enumerate() -> [HALAudioProcess] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        status = ids.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address, 0, nil, &dataSize, buffer.baseAddress!
            )
        }
        guard status == noErr else { return [] }

        return ids.compactMap { id -> HALAudioProcess? in
            HALAudioProcess(
                objectID: id,
                pid: pid(for: id),
                bundleID: bundleID(for: id),
                isRunning: isRunning(for: id)
            )
        }
    }

    private static func pid(for object: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &pid)
        return status == noErr ? pid : -1
    }

    private static func bundleID(for object: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr,
              size > 0 else { return nil }

        var cf: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        let s = cf as String
        return s.isEmpty ? nil : s
    }

    private static func isRunning(for object: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return status == noErr && value != 0
    }
}

// MARK: - ProcessTap

nonisolated enum ProcessTapError: Error, LocalizedError {
    case createTapFailed(OSStatus)
    case readTapUIDFailed(OSStatus)
    case readTapFormatFailed(OSStatus)
    case createAggregateFailed(OSStatus)
    case createIOProcFailed(OSStatus)
    case startDeviceFailed(OSStatus)
    case makeAVFormatFailed

    var errorDescription: String? {
        switch self {
        case .createTapFailed(let s):       return "AudioHardwareCreateProcessTap failed (OSStatus \(s))"
        case .readTapUIDFailed(let s):      return "kAudioTapPropertyUID failed (OSStatus \(s))"
        case .readTapFormatFailed(let s):   return "kAudioTapPropertyFormat failed (OSStatus \(s))"
        case .createAggregateFailed(let s): return "AudioHardwareCreateAggregateDevice failed (OSStatus \(s))"
        case .createIOProcFailed(let s):    return "AudioDeviceCreateIOProcIDWithBlock failed (OSStatus \(s))"
        case .startDeviceFailed(let s):     return "AudioDeviceStart failed (OSStatus \(s))"
        case .makeAVFormatFailed:           return "Could not build AVAudioFormat from tap ASBD"
        }
    }
}

/// Wraps a Core Audio process tap + aggregate device + IO proc. Lifetime
/// is fully owned by the `SystemAudioPipeline`; on `invalidate()` the
/// device is stopped, the IO proc destroyed, and both audio objects are
/// released.
///
/// `@unchecked Sendable` because we hand IO proc callbacks across the
/// real-time audio thread boundary. Mutation is gated through closures
/// captured at creation time; the class itself is otherwise immutable.
nonisolated final class ProcessTap: @unchecked Sendable {

    private let log: Logger
    private let tapID: AudioObjectID
    private let aggregateID: AudioObjectID
    private let ioProcID: AudioDeviceIOProcID
    /// Holds the FluidAudio resampler — every callback converts the tap's
    /// native format (often 48 kHz stereo Float32) to 16 kHz mono Float32 for
    /// VAD/ASR. Behind a lock because the IO proc thread is real-time and
    /// must never reach into actor state.
    private let converterBox: ConverterBox
    private let avFormat: AVAudioFormat

    private init(
        tapID: AudioObjectID,
        aggregateID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID,
        avFormat: AVAudioFormat,
        converterBox: ConverterBox,
        log: Logger
    ) {
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.ioProcID = ioProcID
        self.avFormat = avFormat
        self.converterBox = converterBox
        self.log = log
    }

    /// Build a process tap targeting every `AudioObjectID` in
    /// `targetObjectIDs`, wrap it in a private aggregate device, install an
    /// IO proc that converts each buffer to 16 kHz mono Float32, and start
    /// the device. Multiple targets at once so that — for Electron-style
    /// apps like new Teams where a renderer helper produces call audio but
    /// a notification helper produces notification sounds — both are caught
    /// by a single tap. Throws on every failure path so the pipeline can
    /// bucket each as `.tapDetach`.
    static func attach(
        targetObjectIDs: [AudioObjectID],
        description targetDescription: String,
        log: Logger,
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onCallback: @escaping @Sendable () -> Void,
        onFormat: @escaping @Sendable (Double, UInt32) -> Void,
        onDetach: @escaping @Sendable (String) -> Void
    ) throws -> ProcessTap {

        // 1. Build the tap description. Mono mixdown is what we want for ASR —
        //    Parakeet's input is 16 kHz mono Float32, and asking the HAL to
        //    pre-mix saves us a stereo→mono pass downstream.
        let description = CATapDescription(monoMixdownOfProcesses: targetObjectIDs)
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "EarShot Process Tap (\(targetDescription))"

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let createStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard createStatus == noErr, tapID != kAudioObjectUnknown else {
            throw ProcessTapError.createTapFailed(createStatus)
        }
        log.info("AudioHardwareCreateProcessTap OK. tapID=\(tapID)")

        // 2. Resolve the tap UID — the aggregate device needs it.
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var tapUID: CFString = "" as CFString
        let uidStatus = withUnsafeMutablePointer(to: &tapUID) { ptr -> OSStatus in
            AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &uidSize, ptr)
        }
        guard uidStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw ProcessTapError.readTapUIDFailed(uidStatus)
        }

        // 3. Build a private aggregate device that contains the tap as its
        //    sub-tap. AudioDeviceCreateIOProcIDWithBlock requires a device,
        //    not a bare tap, so this step is mandatory.
        let aggregateUID = UUID().uuidString
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EarShot Tap Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID as String,
                    kAudioSubTapDriftCompensationKey: 1,
                ] as [String: Any]
            ],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID)
        guard aggStatus == noErr, aggregateID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            throw ProcessTapError.createAggregateFailed(aggStatus)
        }
        log.info("AudioHardwareCreateAggregateDevice OK. aggregateID=\(aggregateID)")

        // 4. Read the tap's stream format — we need this to wrap the IO proc
        //    AudioBufferList as an AVAudioPCMBuffer before resampling.
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fmtStatus = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &asbdSize, &asbd)
        guard fmtStatus == noErr else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw ProcessTapError.readTapFormatFailed(fmtStatus)
        }
        guard let avFormat = AVAudioFormat(streamDescription: &asbd) else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw ProcessTapError.makeAVFormatFailed
        }

        log.info("Tap format: sampleRate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) bytesPerFrame=\(asbd.mBytesPerFrame) formatID=\(asbd.mFormatID)")

        // 5. Install the IO proc. Callback fires on Core Audio's real-time
        //    thread; we keep work small (resample + yield) and hop into the
        //    actor via a Task in the consumer side.
        let converterBox = ConverterBox()
        let avFormatRef = avFormat
        let logRef = log

        let ioBlock: AudioDeviceIOBlock = { _, inputData, _, _, _ in
            onCallback()

            let buf = inputData.pointee.mBuffers
            let bytesPerFrame = avFormatRef.streamDescription.pointee.mBytesPerFrame
            guard bytesPerFrame > 0 else { return }
            let frameCount = buf.mDataByteSize / bytesPerFrame
            guard frameCount > 0 else { return }

            onFormat(avFormatRef.sampleRate, avFormatRef.channelCount)

            guard let pcm = AVAudioPCMBuffer(
                pcmFormat: avFormatRef,
                bufferListNoCopy: inputData,
                deallocator: nil
            ) else { return }
            pcm.frameLength = AVAudioFrameCount(frameCount)

            let resampled = converterBox.convert(pcm, log: logRef)
            guard let samples = resampled, !samples.isEmpty else { return }
            onSamples(samples)
        }

        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, ioBlock)
        guard procStatus == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw ProcessTapError.createIOProcFailed(procStatus)
        }

        // 6. Start IO. If the user hasn't granted system-audio recording yet,
        //    this is where the TCC prompt fires (the docs are explicit:
        //    "the first time you start recording from an aggregate device
        //    that contains a tap").
        log.info("Starting aggregate device IO. If TCC has not been granted, the system audio recording prompt should appear now.")
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw ProcessTapError.startDeviceFailed(startStatus)
        }

        // 7. Observe IsAlive on the aggregate so we surface a detach if the
        //    target app quits mid-call. We just notify the pipeline; pipeline
        //    handles the teardown + retry.
        installAliveListener(aggregateID: aggregateID, onDetach: onDetach)

        return ProcessTap(
            tapID: tapID,
            aggregateID: aggregateID,
            ioProcID: procID,
            avFormat: avFormat,
            converterBox: converterBox,
            log: log
        )
    }

    private static func installAliveListener(
        aggregateID: AudioObjectID,
        onDetach: @escaping @Sendable (String) -> Void
    ) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(aggregateID, &addr, DispatchQueue.main) { _, _ in
            onDetach("kAudioDevicePropertyDeviceIsAlive fired (target quit?)")
        }
    }

    func invalidate() {
        AudioDeviceStop(aggregateID, ioProcID)
        AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }
}

// MARK: - Thread-safe helpers

/// Counter incremented from the IO proc real-time thread and read from the
/// actor. `OSAllocatedUnfairLock` would be cleaner but isn't available on
/// 14.6 deployment; `NSLock` is fine for a single integer.
nonisolated final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value &+= 1
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        _value = 0
    }
}

/// Holds the FluidAudio resampler. The IO proc thread serializes calls per
/// device but we keep the lock so that future paths (e.g. teardown racing
/// the callback) don't trip on a non-Sendable converter.
nonisolated final class ConverterBox: @unchecked Sendable {
    private let lock = NSLock()
    private let converter = AudioConverter()

    func convert(_ buffer: AVAudioPCMBuffer, log: Logger) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        do {
            return try converter.resampleBuffer(buffer)
        } catch {
            log.error("System tap resample failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
