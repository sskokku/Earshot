//
//  AppDelegate.swift
//  EarShot
//

import AppKit
import FluidAudio
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    lazy var panelController = TranscriptPanelController(appState: appState)
    let settingsModel = SettingsModel()
    lazy var settingsController = SettingsWindowController(model: settingsModel)
    private let onboardingController = OnboardingWindowController()
    /// First-launch recording-consent gate. Blocks every audio path until
    /// the user accepts the disclaimer; see `ConsentGate.swift`.
    private let consentGateController = ConsentGateController()
    private let log = Logger(subsystem: "com.earshot.app", category: "AppDelegate")

    /// Strong reference; lazy-loaded after onboarding/launch.
    private var micPipeline: MicPipeline?
    /// Phase 2 / C1 — separate actor per CLAUDE.md rule 1. Boots alongside the
    /// mic pipeline, attaches a Core Audio process tap when an allow-listed
    /// meeting app starts producing audio, and pushes `.system` segments via
    /// the same handlers wired below.
    private var systemPipeline: SystemAudioPipeline?
    private var startupTask: Task<Void, Never>?

    /// Daily Markdown writer. Lives for the app's lifetime; folder is
    /// swappable from settings without an app restart.
    private let transcriptWriter = TranscriptWriter(folder: AppSettings.transcriptsFolder)

    /// Phase 1 metrics collector. Same folder as the transcript writer so the
    /// `YYYY-MM-DD.metrics.json` sidecar lands next to `YYYY-MM-DD.md`.
    private let metrics = MetricsCollector(folder: AppSettings.transcriptsFolder)

    /// Phase 2 / C2 — CLAUDE.md rules 7 + 8. Single funnel for finalized
    /// segments from both pipelines. Owns echo dedupe today; will own
    /// persistent speaker identity in S3.
    private let mergeLayer = MergeLayer()

    /// Phase 3 / S2 — SQLite (GRDB) speaker + embedding storage. Boots on
    /// app launch (one DB file in Application Support). Shared by both
    /// pipelines so embedding writes from mic and system land in one
    /// store; CLAUDE.md rule 1 is not violated because the library only
    /// sees post-finalize data, not the live audio buffers themselves.
    private var speakerLibrary: SpeakerLibrary?

    /// S2 — shared WeSpeaker embedding extractor. Single instance (the
    /// pyannote+WeSpeaker bundle is ~250 MB; doubling it would be silly).
    /// CLAUDE.md rule 1 holds: extraction is stateless across calls.
    private var embeddingExtractor: EmbeddingExtractor?

    /// S3 — persistent identity engine (rule 8). Lives behind the merge
    /// layer so no other component touches identity. Boots once after the
    /// speaker library is open; both pipelines feed it via the merge
    /// layer's FinalizedSegment carrier.
    private var identityResolver: IdentityResolver?

    /// S4 — speaker library management window. Owned by AppDelegate so
    /// menu items, the floating panel's "Speakers" button, and the
    /// settings deep-link all open the same window instance.
    private var speakerLibraryWindowModel: SpeakerLibraryWindowModel?
    private var speakerLibraryWindowController: SpeakerLibraryWindowController?

    /// S4 — recorder + downloader reused by the speaker window's
    /// "Re-enroll Me" flow. Lazy so they only initialize when needed.
    private let enrollmentRecorder = EnrollmentRecorder()
    private let modelDownloader = ModelDownloader()

    /// CP1 / Phase 4 — offline correction pass. Owns its own
    /// DiarizerManager (~250 MB) so the EmbeddingExtractor's manager
    /// state isn't disturbed by `performCompleteDiarization` calls. Runs
    /// every 5 min against the rolling buffers exposed by the two
    /// pipelines; pauses under thermal pressure.
    private var correctionPass: CorrectionPass?

    /// H1 — PRD R8 disk log at `~/Earshot/logs/`. Mirrors metrics-class
    /// errors + crash recovery markers + gap markers per the PRD's
    /// "logged to ~/Earshot/logs/" line. Daily-rotated, 30-day retention.
    private let fileLogger = FileLogger(folder: AppSettings.logsFolder)

    /// H1 — debug soak harness. Only constructed when
    /// `AppSettings.soakModeEnabled` is true. See `SoakHarness.swift`.
    private var soakHarness: SoakHarness?

    /// H1 — periodic metrics flush throttle. The 30 s sampler is too
    /// frequent for a full JSON write; we only flush when this much
    /// wall clock has elapsed since the last flush. A crash loses at
    /// most this window of counters.
    private var lastMetricsFlushAt: Date = .distantPast
    private let metricsFlushInterval: TimeInterval = 300

    /// Cmd+Shift+E. Toggles pause/resume from any app, no key window required.
    private var pauseHotkey: GlobalHotkey?

    /// Guards against double-fires (user mashes the hotkey while the engine
    /// is mid-teardown).
    private var pauseInFlight = false

    // MARK: Survival assertions and monitors

    private let appNap = AppNapAssertion()
    private let sleepAssertion = SleepAssertion()
    private var thermalMonitor: ThermalMonitor?
    private var sleepWakeMonitor: SleepWakeMonitor?
    private var sampleTimer: Timer?

    /// Last time the system told us it was about to sleep. Compared against
    /// `didWake` to compute the gap-marker duration.
    private var lastWillSleepAt: Date?

    /// Whether the most recent `applicationShouldTerminate` finalize cycle
    /// has completed. Lets a repeat invocation bypass the cleanup path.
    private var terminationCleanupDone = false

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only. Backs up LSUIElement so we never show a Dock icon.
        NSApp.setActivationPolicy(.accessory)

        // Settings model bridges UI folder picks back to the writer + metrics.
        // Both must point at the same folder so the .md and .metrics.json
        // sidecar stay colocated.
        settingsModel.onFolderChange = { [weak self] url in
            guard let self else { return }
            Task { await self.transcriptWriter.setFolder(url) }
            Task { await self.metrics.setFolder(url) }
        }

        // Hand the writer a reference to metrics so it can map disk failures
        // into the taxonomy without needing a callback at every write site.
        Task { [transcriptWriter, metrics] in
            await transcriptWriter.setMetrics(metrics)
        }

        // Summary appender bridges the metrics-side rollover/finalize calls
        // back to the writer; only one component owns the .md file handle.
        Task { [transcriptWriter, metrics] in
            await metrics.setSummaryAppender { text, dateKey in
                await transcriptWriter.appendSummary(text, dateKey: dateKey)
            }
        }

        // H1 — wire the disk logger so error events get mirrored to
        // ~/Earshot/logs/ for forensic review. Prune on boot so a long
        // gap between launches doesn't leave a year of dead logs around.
        Task { [fileLogger, metrics] in
            await metrics.setFileLogger(fileLogger)
            await fileLogger.pruneOldLogs()
        }

        // H1 — crash recovery: if the prior process didn't clear the
        // running flag, write a "recovered HH:MM:SS" marker into today's
        // transcript so a human reader sees the boundary. Then mark this
        // session running. Cleanup clears the flag on graceful exit.
        handleCrashRecoveryIfNeeded()
        AppSettings.runningSessionFlag = true
        AppSettings.runningSessionStartedAt = Date()

        registerPauseHotkey()
        startThermalMonitor()
        startSleepWakeMonitor()
        startPeriodicSampler()
        appNap.acquire(reason: "Continuous ambient transcription")

        // Mirror the system's launch-at-login state into settingsModel so the
        // toggle's initial value reflects reality on first sheet present.
        settingsModel.launchAtLogin = LoginItem.isEnabled

        // Recording-consent gate runs BEFORE onboarding so no audio path
        // (model load, mic permission prompt, enrollment) can start until
        // the user accepts the disclaimer. After acceptance — or if the
        // user already accepted on a prior launch — we proceed into the
        // existing onboarding-or-listen path.
        let gateShown = consentGateController.presentIfNeeded { [weak self] in
            self?.continueLaunchAfterConsent()
        }
        if !gateShown {
            continueLaunchAfterConsent()
        }
    }

    /// Called after the consent gate is satisfied (either freshly accepted
    /// or already on file from a prior launch). Owns the onboarding/listen
    /// branch the original `applicationDidFinishLaunching` used to run
    /// inline.
    private func continueLaunchAfterConsent() {
        let didShowOnboarding = onboardingController.presentIfNeeded { [weak self] in
            self?.startListening()
        }

        if !didShowOnboarding {
            startListening()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // CLAUDE.md "Metrics and errors" §: flush on clean quit. The async
        // finalize work cannot fit inside `applicationWillTerminate` (sync),
        // so we defer the termination, finish the work, then signal back.
        if terminationCleanupDone { return .terminateNow }
        Task { [weak self] in
            await self?.cleanupForTermination()
            await MainActor.run {
                self?.terminationCleanupDone = true
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Best-effort fallback if shouldTerminate was bypassed (e.g. SIGTERM).
        pauseHotkey?.unregister()
        thermalMonitor?.stop()
        sleepWakeMonitor?.stop()
        sampleTimer?.invalidate()
        sleepAssertion.release()
        appNap.release()
    }

    private func cleanupForTermination() async {
        pauseHotkey?.unregister()
        thermalMonitor?.stop()
        sleepWakeMonitor?.stop()
        sampleTimer?.invalidate()
        sleepAssertion.release()
        appNap.release()

        if let harness = soakHarness {
            await harness.stop()
        }
        if let pass = correctionPass {
            await pass.stop()
        }
        if let pipeline = micPipeline {
            await pipeline.stop()
        }
        if let sys = systemPipeline {
            await sys.stop()
        }
        await metrics.finalize()
        await transcriptWriter.close()
        await fileLogger.close()
        // H1 — clean exit. The next launch will see this flag clear and
        // skip the crash-recovery marker.
        AppSettings.runningSessionFlag = false
        AppSettings.runningSessionStartedAt = nil
    }

    // MARK: H1 — crash recovery

    /// On launch, if the previous process left the running flag set,
    /// schedule a `recovered HH:MM:SS` marker on today's transcript so a
    /// human reader can see where the prior session ended. The Markdown
    /// file is append-only and fsynced per line (rule 4) so no repair is
    /// needed — only the marker is informational. The segments table is
    /// keyed on fresh wall-clock timestamps so no duplicate rows can
    /// arise from resumption.
    private func handleCrashRecoveryIfNeeded() {
        guard AppSettings.runningSessionFlag else { return }
        let prevStartedAt = AppSettings.runningSessionStartedAt
        let now = Date()
        log.error("Detected unclean prior exit (running flag was still set, prevStartedAt=\(prevStartedAt?.description ?? "nil", privacy: .public))")
        Task { [transcriptWriter, fileLogger, metrics] in
            await transcriptWriter.writeMarker(.crashRecovered, at: now)
            await fileLogger.record(.warning, category: "Lifecycle", message: "crash recovery: prior session did not exit cleanly (prevStartedAt=\(prevStartedAt?.description ?? "nil"))", at: now)
            // Bucket as a route-change recovery attempt — the existing
            // taxonomy doesn't have a dedicated "crash" class, and
            // route-change is the closest "we lost capture and rebuilt"
            // event already on the books. CLAUDE.md error taxonomy is
            // intentionally tight (six classes), and adding "crashRecovery"
            // would force every emitter to think about it. The summary
            // surface (gapMarkers) is what humans read.
            await metrics.recordRecoveryAttempt(.routeChange)
        }
    }

    // MARK: Pause hotkey

    private func registerPauseHotkey() {
        let hotkey = GlobalHotkey(onPress: { [weak self] in
            self?.togglePause()
        })
        hotkey.register()
        pauseHotkey = hotkey
    }

    func togglePause() {
        guard !pauseInFlight else { return }
        guard let pipeline = micPipeline else {
            // Pipeline not booted yet (still in onboarding or model load).
            // Nothing to pause.
            return
        }

        switch appState.status {
        case .listening:
            pauseInFlight = true
            let now = Date()
            // Glyph flips first so the user sees instant feedback even if
            // engine teardown takes a beat.
            appState.status = .paused
            Task { [weak self] in
                guard let self else { return }
                await self.transcriptWriter.writeMarker(.paused, at: now)
                await self.metrics.notePaused(at: now)
                await self.metrics.flush()  // pause is a flush trigger
                await pipeline.pause()
                if let sys = self.systemPipeline { await sys.pause() }
                self.pauseInFlight = false
                self.refreshSurvivalAssertions()
            }
        case .paused:
            pauseInFlight = true
            let now = Date()
            appState.status = .listening
            Task { [weak self] in
                guard let self else { return }
                await self.transcriptWriter.writeMarker(.resumed, at: now)
                await self.metrics.noteResumed(at: now)
                await pipeline.resume()
                if let sys = self.systemPipeline { await sys.resume() }
                self.pauseInFlight = false
                self.refreshSurvivalAssertions()
            }
        case .idle, .error:
            // Nothing meaningful to toggle from idle/error.
            return
        }
    }

    // MARK: Mic pipeline boot

    private func startListening() {
        panelController.show()

        // Idempotent: do not re-spin the pipeline if one is already coming up.
        guard startupTask == nil, micPipeline == nil else { return }

        startupTask = Task { [weak self] in
            await self?.bootMicPipeline()
        }
    }

    private func bootMicPipeline() async {
        do {
            // After onboarding, both bundles are on disk; these calls are cache
            // hits per ModelDownloader.swift's note. Loading still costs the
            // Core ML compile, so we surface progress via the menu bar glyph.
            log.info("Loading ASR models for mic pipeline")
            let asrModels = try await AsrModels.downloadAndLoad(version: .v3)
            let asrManager = AsrManager(config: .default, models: asrModels)

            log.info("Loading VAD model for mic pipeline")
            let vad = try await VadManager()

            log.info("Loading Sortformer diarizer for mic pipeline")
            let diarizer = try await DiarizerActor.bootDefault()

            // S2 — open the persistent speaker library and run the one-shot
            // migration from Chunk 2's me_embedding.bin if it's the first
            // launch since GRDB was introduced. Boot the shared WeSpeaker
            // embedding extractor on the same diarizer bundle so both
            // pipelines can write embeddings from finalized segments.
            log.info("Opening speaker library + embedding extractor + identity resolver")
            let library = try SpeakerLibrary()
            _ = try? await library.migrateOwnerEmbeddingFileIfNeeded()
            self.speakerLibrary = library
            let extractor = try await EmbeddingExtractor.boot()
            self.embeddingExtractor = extractor

            // S3 — IdentityResolver owns chunk-local-slot → persistent
            // speaker-id mapping for BOTH pipelines, behind the merge layer
            // (rule 8). Pipelines never see it directly.
            let resolver = IdentityResolver(library: library)
            self.identityResolver = resolver
            await mergeLayer.setIdentityResolver(resolver)

            // S4 — boot the speaker library window model + wire panel
            // actions so the inline naming + search affordances in the
            // floating panel are live.
            setupSpeakerLibraryWindow(library: library, resolver: resolver)
            wirePanelActions(library: library)

            let pipeline = MicPipeline(asr: asrManager, vad: vad)
            self.micPipeline = pipeline

            await pipeline.setMetrics(metrics)
            await pipeline.setDiarizer(diarizer)
            await pipeline.setSpeakerLibrary(library)
            await pipeline.setEmbeddingExtractor(extractor)

            let writer = transcriptWriter
            let metricsRef = metrics
            let appStateRef = appState
            let libraryRef = library
            let mergeRef = mergeLayer

            // The merge layer funnels both pipelines' finalized segments
            // through a single point so echo dedupe can drop matching mic
            // copies before they reach the panel or disk (CLAUDE.md rule 7).
            // S4 — every forwarded segment also gets indexed into the
            // SQLite segments table (and the FTS5 virtual mirror via
            // GRDB-installed triggers) so keyword search has live data.
            await mergeLayer.setHandlers(
                onForward: { forwarded in
                    Task { @MainActor in
                        appStateRef.transcript.appendFinalized(forwarded.segment)
                    }
                    Task {
                        await writer.append(segment: forwarded.segment)
                    }
                    if let sessionID = forwarded.sessionID {
                        let segment = forwarded.segment
                        let context: SpeakerLibrary.Context = (segment.source == .mic) ? .mic : .system
                        let dateKey = Self.transcriptDateKey(from: segment.startedAt)
                        let record = SpeakerLibrary.SegmentRecord(
                            speakerID: forwarded.speakerID,
                            context: context,
                            sessionID: sessionID.uuidString,
                            startedAt: segment.startedAt,
                            endedAt: segment.endedAt,
                            dateKey: dateKey,
                            text: segment.text,
                            provisional: segment.provisional
                        )
                        Task {
                            do {
                                _ = try await libraryRef.indexSegment(record)
                            } catch {
                                await metricsRef.recordError(.diskWriteFailure)
                            }
                        }
                    }
                },
                onDropped: { _, reason in
                    switch reason {
                    case .echo:
                        Task { await metricsRef.recordEchoDropped() }
                    }
                }
            )

            await pipeline.setHandlers(
                onProvisional: { [weak self] text in
                    Task { @MainActor [weak self] in
                        self?.appState.transcript.updateProvisional(text)
                    }
                },
                onFinalized: { payload in
                    // S3: payload carries embedding + slot label + session id
                    // so the merge layer's resolver can rewrite the speaker
                    // label to a persistent identity before disk/panel.
                    Task {
                        await mergeRef.submit(payload)
                    }
                },
                onStatusChange: { [weak self] status in
                    Task { @MainActor [weak self] in
                        self?.handlePipelineStatus(status)
                    }
                }
            )

            await pipeline.start()

            // Phase 2 / C1 — stand up the system-audio pipeline alongside the
            // mic. Shares the loaded ASR/VAD models (per-pipeline state is the
            // only thing that needs to be separate per CLAUDE.md rule 1; the
            // models themselves are stateless across `transcribe` calls). The
            // system diarizer is a separate `DiarizerActor` instance so its
            // slot map doesn't pollute the mic side.
            log.info("Loading Sortformer diarizer for system pipeline")
            let systemDiarizer = try await DiarizerActor.bootDefault()

            let sysPipeline = SystemAudioPipeline(asr: asrManager, vad: vad)
            self.systemPipeline = sysPipeline
            await sysPipeline.setMetrics(metrics)
            await sysPipeline.setDiarizer(systemDiarizer)
            await sysPipeline.setSpeakerLibrary(library)
            await sysPipeline.setEmbeddingExtractor(extractor)

            await sysPipeline.setHandlers(
                onProvisional: { _ in
                    // System-side provisional intentionally not surfaced — the
                    // floating panel only shows mic provisional today, since
                    // two concurrent provisional lines fight for the same
                    // visual slot. Finalized system segments still appear.
                },
                onFinalized: { payload in
                    // System always forwards (it wins echo conflicts), but
                    // we still route through the merge layer so the resolver
                    // can rewrite the system slot to a persistent identity
                    // and the dedupe + disk/panel sinks stay single-source.
                    Task {
                        await mergeRef.submit(payload)
                    }
                },
                onStatusChange: { [weak self] status in
                    Task { @MainActor [weak self] in
                        self?.handleSystemPipelineStatus(status)
                    }
                }
            )

            await sysPipeline.start()

            // CP1 — boot the offline correction pass and wire it to both
            // pipelines. Lives behind the merge layer's identity surface
            // (it talks to `IdentityResolver` directly, same as the
            // merge layer does on the live path) so rule 8 still holds.
            log.info("Booting offline correction pass")
            let pass = try await CorrectionPass.boot(
                library: library,
                resolver: resolver,
                writer: writer,
                metrics: metrics,
                liveTranscript: appState.transcript
            )
            self.correctionPass = pass
            await pass.setPipelines(mic: pipeline, system: sysPipeline)
            await pass.start()

            // H1 — soak harness is opt-in via `-EarShotSoakMode YES`
            // launch argument. Production users never see it; CI / soak
            // verification runs flip the flag and let it run for hours
            // while writing per-minute samples to ~/Earshot/logs/.
            if AppSettings.soakModeEnabled {
                log.info("Soak mode enabled; booting SoakHarness")
                let harness = SoakHarness(
                    logsFolder: AppSettings.logsFolder,
                    metrics: metrics,
                    mic: pipeline,
                    system: sysPipeline
                )
                self.soakHarness = harness
                await harness.start()
            }
        } catch {
            log.error("Mic pipeline boot failed: \(error.localizedDescription, privacy: .public)")
            await metrics.recordError(.modelLoadFailure)
            appState.status = .error
            appState.lastErrorMessage = error.localizedDescription
        }
        startupTask = nil
    }

    /// System pipeline status doesn't drive the menu-bar glyph (mic is the
    /// always-on signal). It DOES drive the merge layer's `systemActive`
    /// flag so mic segments only pay the dedupe hold when a tap is actually
    /// attached.
    private func handleSystemPipelineStatus(_ status: SystemAudioPipeline.Status) {
        let active: Bool
        switch status {
        case .stopped:
            log.info("System pipeline status: stopped")
            active = false
        case .waitingForTarget:
            log.info("System pipeline status: waiting for an allow-listed audio target")
            active = false
        case .listening:
            log.info("System pipeline status: listening (tap attached)")
            active = true
        case .paused:
            log.info("System pipeline status: paused")
            active = false
        case .failed(let msg):
            log.error("System pipeline failed: \(msg, privacy: .public)")
            active = false
        }
        Task { [mergeLayer] in await mergeLayer.setSystemActive(active) }
    }

    private func handlePipelineStatus(_ status: MicPipeline.Status) {
        // When the user hits the pause hotkey we update `appState.status`
        // optimistically BEFORE telling the pipeline. The pipeline then emits
        // `.paused` once it has actually torn down. We must not let a stale
        // `.stopped` reset the glyph during that handoff — `pauseInFlight`
        // guards the explicit user-pause path, but for everything else this
        // reflects the pipeline's reality.
        switch status {
        case .stopped:
            if appState.status != .paused {
                appState.status = .idle
            }
            Task { await metrics.noteListeningStopped() }
            refreshSurvivalAssertions()
        case .listening:
            appState.status = .listening
            appState.lastErrorMessage = nil
            appState.noteRecoverySucceeded()
            Task { await metrics.noteListeningStarted() }
            refreshSurvivalAssertions()
        case .paused:
            appState.status = .paused
            refreshSurvivalAssertions()
        case .failed(let message):
            // CLAUDE.md: glyph error state only after N consecutive failed
            // recoveries. Bump the counter; if we hit threshold, surface as
            // .error. Otherwise schedule a single retry — `start()` will fire
            // a fresh status event whose .listening/.failed will either reset
            // the counter or bump it again.
            appState.lastErrorMessage = message
            Task { await metrics.noteListeningStopped() }
            refreshSurvivalAssertions()
            let atThreshold = appState.noteRecoveryFailed()
            if atThreshold {
                appState.status = .error
            } else {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self else { return }
                    if let pipeline = self.micPipeline {
                        await self.metrics.recordRecoveryAttempt(.routeChange)
                        await pipeline.start()
                    }
                }
            }
        }
    }

    // MARK: Survival hardening

    private func startThermalMonitor() {
        let monitor = ThermalMonitor { [weak self] state in
            guard let self else { return }
            let isHigh = (state == .serious || state == .critical)
            Task { [weak self] in
                guard let self else { return }
                if let pipeline = self.micPipeline {
                    await pipeline.setThermalPressure(isHigh)
                }
                if let sys = self.systemPipeline {
                    await sys.setThermalPressure(isHigh)
                }
                // CP1 — pause the offline correction pass when the system
                // climbs to .serious / .critical. The pass is the most
                // expensive ANE-bound thing we run; backing it off under
                // heat lines up with the survival checklist's intent.
                if let pass = self.correctionPass {
                    await pass.setThermalThrottle(isHigh)
                }
            }
        }
        monitor.start()
        thermalMonitor = monitor
    }

    private func startSleepWakeMonitor() {
        let monitor = SleepWakeMonitor(
            onSleep: { [weak self] in
                guard let self else { return }
                self.lastWillSleepAt = Date()
            },
            onWake: { [weak self] in
                guard let self else { return }
                self.handleDidWake()
            }
        )
        monitor.start()
        sleepWakeMonitor = monitor
    }

    private func handleDidWake() {
        // CLAUDE.md long-run survival §: "on battery, allow sleep and write a
        // gap marker on wake". If we were listening before sleep AND we are
        // on battery, the system was allowed to sleep, and we missed audio
        // between willSleep and didWake. One marker, one metric bump.
        let wokeAt = Date()
        defer { lastWillSleepAt = nil }
        guard let sleptAt = lastWillSleepAt, !PowerSource.isOnAC() else { return }
        guard appState.status == .listening || appState.status == .paused else { return }
        Task { [transcriptWriter, metrics] in
            await transcriptWriter.writeGapMarker(from: sleptAt, to: wokeAt)
            await metrics.recordGapMarker(at: wokeAt)
        }
    }

    private func startPeriodicSampler() {
        // 30 s is plenty for the long-run survival checks. We DO sample memory
        // here (peak-memory metric) and the power state (sleep assertion
        // policy). Thermal state has its own notification, not polled.
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.runPeriodicSample()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
    }

    private func runPeriodicSample() {
        let bytes = MemorySampler.residentBytes()
        let now = Date()
        Task { [metrics] in
            await metrics.recordMemorySnapshot(bytes: bytes)
            await metrics.tick()  // catch a silent midnight crossing
        }
        // H1 — periodic flush so a crash loses at most `metricsFlushInterval`
        // worth of counters. flush() writes the day's JSON sidecar; cheap
        // (sub-millisecond for a small dictionary) but not free, so we
        // throttle to 5 min instead of the 30 s sampler cadence.
        if now.timeIntervalSince(lastMetricsFlushAt) >= metricsFlushInterval {
            lastMetricsFlushAt = now
            Task { [metrics] in
                await metrics.flush()
            }
        }
        refreshSurvivalAssertions()
    }

    // MARK: S4 — speaker library window + rename flow

    private func setupSpeakerLibraryWindow(library: SpeakerLibrary, resolver: IdentityResolver) {
        let writer = transcriptWriter
        let model = SpeakerLibraryWindowModel(
            library: library,
            writer: writer,
            resolver: resolver,
            downloader: modelDownloader,
            recorder: enrollmentRecorder,
            transcriptFolderProvider: { AppSettings.transcriptsFolder },
            onChange: { [weak self] in
                // A rename / merge / delete is a local invalidation; the
                // panel will pick up the new label on the next segment
                // because IdentityResolver.invalidate dropped its cache.
                // We do not retroactively rewrite segments already in
                // memory — they reflect what landed on disk at write
                // time, and the file has just been rewritten to match.
                _ = self
            }
        )
        self.speakerLibraryWindowModel = model
        self.speakerLibraryWindowController = SpeakerLibraryWindowController(model: model)
    }

    func showSpeakerLibraryWindow() {
        if speakerLibraryWindowController == nil {
            presentSimpleAlert(title: "Speaker Library", message: "Library not loaded yet. Finish onboarding first.")
            return
        }
        speakerLibraryWindowController?.show()
    }

    private func wirePanelActions(library: SpeakerLibrary) {
        let actions = PanelActions(
            renameSpeaker: { [weak self] segment in
                guard let self else { return }
                self.beginRenameSheet(for: segment)
            },
            runSearch: { [weak self, library] query in
                guard let self else { return [] }
                return await self.performSearch(query: query, library: library)
            },
            openSpeakerLibrary: { [weak self] in
                self?.showSpeakerLibraryWindow()
            }
        )
        panelController.setActions(actions)
    }

    /// Inline naming sheet for a transcript row. The segment carries
    /// `speakerID` once IdentityResolver has run; we use that directly so
    /// the rename targets exactly the right persistent identity even if
    /// there are two "Speaker 3" rows hanging around from older builds.
    private func beginRenameSheet(for segment: LiveTranscript.Segment) {
        guard let speakerID = segment.speakerID else {
            presentSimpleAlert(
                title: "Cannot Name",
                message: "This segment hasn't been resolved to a persistent speaker yet. Wait for the next utterance from this voice and try again."
            )
            return
        }
        let initial = segment.speakerLabel ?? ""
        let suggested = initial.hasPrefix("Speaker ") ? "" : initial

        let alert = NSAlert()
        alert.messageText = "Name this speaker"
        alert.informativeText = "Currently \"\(initial.isEmpty ? "Speaker ?" : initial)\". Today's transcript will be retroactively relabeled."
        alert.alertStyle = .informational
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name"
        field.stringValue = suggested
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task { [weak self] in
            await self?.performRename(speakerID: speakerID, newName: trimmed)
        }
    }

    private func performRename(speakerID: Int64, newName: String) async {
        guard let library = speakerLibrary else { return }
        do {
            let dateKey = Self.transcriptDateKey(from: Date())
            let outcome = try await library.renameSpeaker(
                speakerID: speakerID,
                newName: newName,
                todayDateKey: dateKey,
                transcriptFolder: AppSettings.transcriptsFolder,
                writer: transcriptWriter
            )
            await identityResolver?.invalidate(speakerID: speakerID)
            log.info("Inline rename: speaker=\(speakerID) → \"\(outcome.newLabel, privacy: .public)\", relabeled \(outcome.relabeledSegmentCount) line(s)")
            if let model = speakerLibraryWindowModel {
                await model.refresh()
            }
        } catch {
            log.error("Inline rename failed: \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                self.presentSimpleAlert(title: "Rename Failed", message: error.localizedDescription)
            }
        }
    }

    /// PRD R8 — log every query locally so the future AI-layer decision
    /// has usage data behind it. Failures here don't block the result
    /// list (the user still gets their hits); they only mean we missed
    /// one log row.
    private func performSearch(query: String, library: SpeakerLibrary) async -> [SpeakerLibrary.SearchHit] {
        do {
            let hits = try await library.searchSegments(query: query)
            do {
                try await library.logSearch(query: query, resultCount: hits.count)
                await metrics.recordSearch()
            } catch {
                log.error("Search log write failed: \(error.localizedDescription, privacy: .public)")
            }
            return hits
        } catch {
            log.error("Search failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: Debug

    /// Debug-menu action. Fetches counts from the SQLite speaker library
    /// and surfaces them in an alert so first-run enrollment / per-session
    /// embedding accrual can be eyeballed without dropping to sqlite3.
    /// CLAUDE.md rule 6 ("fail quiet") is intentionally bypassed here —
    /// this is a debug surface, not an ambient one.
    func showSpeakerLibraryDump() {
        guard let library = speakerLibrary else {
            presentSimpleAlert(title: "Speaker Library", message: "Library not loaded yet. Finish onboarding and let the mic pipeline boot first.")
            return
        }
        Task { [weak self] in
            do {
                let counts = try await library.dumpCounts()
                await MainActor.run {
                    self?.presentSimpleAlert(title: "Speaker Library", message: Self.renderCounts(counts))
                }
            } catch {
                await MainActor.run {
                    self?.presentSimpleAlert(title: "Speaker Library Error", message: error.localizedDescription)
                }
            }
        }
    }

    /// Day-key formatter matching `TranscriptWriter`'s YYYY-MM-DD scheme.
    /// Used by the S4 segment-index path so the on-disk Markdown file and
    /// the segments table agree on which day a given timestamp belongs to.
    nonisolated private static let dateKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    nonisolated static func transcriptDateKey(from date: Date) -> String {
        dateKeyFormatter.string(from: date)
    }

    private static func renderCounts(_ c: SpeakerLibrary.Counts) -> String {
        var lines: [String] = []
        lines.append("Speakers: \(c.speakerCount)")
        lines.append("Embeddings: \(c.embeddingCount) (mic \(c.micEmbeddingCount), system \(c.systemEmbeddingCount))")
        if let id = c.ownerSpeakerID {
            lines.append("Owner: \(c.ownerName ?? "(unnamed)") id=\(id), embeddings=\(c.ownerEmbeddingCount)")
        } else {
            lines.append("Owner: (not enrolled)")
        }
        lines.append("")
        lines.append("Top speakers by embedding count:")
        if c.perSpeaker.isEmpty {
            lines.append("  (none)")
        } else {
            for s in c.perSpeaker {
                lines.append("  id=\(s.id) \(s.label): mic=\(s.micCount) system=\(s.systemCount)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func presentSimpleAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Sleep assertion + App Nap policy. CLAUDE.md: sleep assertion only while
    /// listening on AC power. App Nap is held the whole time the app is up
    /// (we are an always-on tool — App Nap would throttle our background
    /// thread to seconds-per-minute, which is incompatible with the spec).
    private func refreshSurvivalAssertions() {
        let isListening = (appState.status == .listening)
        let onAC = PowerSource.isOnAC()
        if isListening && onAC {
            sleepAssertion.acquire(reason: "EarShot is transcribing")
        } else {
            sleepAssertion.release()
        }
    }
}

