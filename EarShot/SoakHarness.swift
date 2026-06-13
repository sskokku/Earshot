//
//  SoakHarness.swift
//  EarShot
//
//  H1 — multi-hour soak harness. Activated only when the launch argument
//  `-EarShotSoakMode YES` (or the equivalent UserDefaults key) is present.
//
//  Two responsibilities:
//
//   1. Generate synthetic multi-speaker PCM and inject it into both
//      pipelines via the debug `injectSoakAudio(_:)` surface. The
//      synthetic signal is three sine carriers (one per "speaker") with
//      a speech-like envelope and pauses; the goal isn't transcript
//      accuracy (sine waves are not speech), it's to exercise the
//      VAD → ASR → diarizer → merge layer → SQLite → file writer chain
//      end to end at a controlled cadence so the long-run survival
//      signals (memory, CPU, thermal, segment counts) come from a
//      reproducible input. Without an input source, a soak on a quiet
//      desk produces zero data.
//   2. Every `sampleInterval` (default 60 s), sample resident memory,
//      process CPU utilization, thermal state, mic+system segment
//      counters, echo dedupe drops, and error totals; write one
//      tab-separated line to `~/Earshot/logs/soak-YYYY-MM-DD-HHmmss.log`.
//      Multi-hour evaluation reads this file directly.
//
//  Architecture-rule check:
//   - Rule 2: the synthetic signal generator hands chunks straight into
//     the pipelines' AsyncStream; no permanent retention in the harness.
//   - Rule 5: synthetic audio is never persisted.
//   - Rule 9: no network calls.
//

import Foundation
import os

actor SoakHarness {
    private let log = Logger(subsystem: "com.earshot.app", category: "SoakHarness")

    private let logsFolder: URL
    private let metrics: MetricsCollector
    private let mic: MicPipeline?
    private let system: SystemAudioPipeline?

    /// 60 s default; tests override down to 10 ms.
    let sampleInterval: TimeInterval
    /// Synthetic-audio chunk cadence. ~250 ms keeps us close to the VAD
    /// chunk size so injected audio rolls through `processVadChunk` as
    /// real audio would, without queueing.
    let injectInterval: TimeInterval

    private var sampleTask: Task<Void, Never>?
    private var injectTask: Task<Void, Never>?

    private var logHandle: FileHandle?
    private var logURL: URL?

    /// Process CPU sampler. Reads `mach_thread_basic_info` totals on each
    /// tick; we compute the delta against the previous sample so the
    /// reported value is "CPU seconds consumed in the last sampleInterval".
    private var lastCPUTotal: Double = 0
    private var lastSampleAt: Date?

    /// Counter snapshots so the periodic line reports deltas vs totals.
    private var lastMicSegments: Int = 0
    private var lastSystemSegments: Int = 0
    private var lastEchoDropped: Int = 0
    private var lastTotalErrors: Int = 0

    init(
        logsFolder: URL,
        metrics: MetricsCollector,
        mic: MicPipeline?,
        system: SystemAudioPipeline?,
        sampleInterval: TimeInterval = 60,
        injectInterval: TimeInterval = 0.25
    ) {
        self.logsFolder = logsFolder
        self.metrics = metrics
        self.mic = mic
        self.system = system
        self.sampleInterval = sampleInterval
        self.injectInterval = injectInterval
    }

    // MARK: Lifecycle

    func start(now: Date = Date()) async {
        guard sampleTask == nil else { return }
        do {
            try openLog(at: now)
            log.info("SoakHarness started; logging every \(self.sampleInterval) s to \(self.logURL?.path ?? "<unknown>", privacy: .public)")
        } catch {
            log.error("SoakHarness failed to open log: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Prime baseline so the first tick reports zero CPU delta rather
        // than the entire process lifetime.
        lastCPUTotal = Self.processCPUSeconds()
        lastSampleAt = now
        let snap = await metrics.snapshot()
        lastMicSegments = snap.micSegments
        lastSystemSegments = snap.systemSegments
        lastEchoDropped = snap.echoDropped
        lastTotalErrors = snap.errors.values.reduce(0, +)

        writeHeader()

        sampleTask = Task { [weak self] in
            await self?.runSampleLoop()
        }
        injectTask = Task { [weak self] in
            await self?.runInjectLoop()
        }
    }

    func stop() async {
        sampleTask?.cancel()
        injectTask?.cancel()
        sampleTask = nil
        injectTask = nil
        if let logHandle {
            try? logHandle.synchronize()
            try? logHandle.close()
        }
        logHandle = nil
        logURL = nil
    }

    // MARK: Sample loop

    /// Public so tests can drive a single tick deterministically.
    func tickOnce(now: Date = Date()) async {
        let snap = await metrics.snapshot()
        let cpuTotal = Self.processCPUSeconds()
        let cpuDelta = max(0, cpuTotal - lastCPUTotal)
        let wallDelta = max(0.001, now.timeIntervalSince(lastSampleAt ?? now))
        let cpuPct = (cpuDelta / wallDelta) * 100.0
        lastCPUTotal = cpuTotal
        lastSampleAt = now

        let micDelta = snap.micSegments - lastMicSegments
        let sysDelta = snap.systemSegments - lastSystemSegments
        let echoDelta = snap.echoDropped - lastEchoDropped
        let totalErrors = snap.errors.values.reduce(0, +)
        let errorDelta = totalErrors - lastTotalErrors
        lastMicSegments = snap.micSegments
        lastSystemSegments = snap.systemSegments
        lastEchoDropped = snap.echoDropped
        lastTotalErrors = totalErrors

        let memBytes = MemorySampler.residentBytes()
        let memMB = Double(memBytes) / (1024 * 1024)
        let thermal = Self.thermalString()

        let ts = ISO8601DateFormatter.soakFormatter.string(from: now)
        // Tab-separated so awk / pandas can parse without quoting rules.
        let line = "\(ts)\t\(String(format: "%.1f", memMB))\t\(String(format: "%.1f", cpuPct))\t\(thermal)\t\(snap.micSegments)\t\(micDelta)\t\(snap.systemSegments)\t\(sysDelta)\t\(snap.echoDropped)\t\(echoDelta)\t\(totalErrors)\t\(errorDelta)\n"
        appendLine(line)
    }

    private func runSampleLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(sampleInterval * 1_000_000_000))
            if Task.isCancelled { return }
            await tickOnce()
        }
    }

    // MARK: Inject loop

    /// 3-speaker carrier set with offsets so all three are not active at
    /// once. Each "speaker" is a sine with a slow amplitude envelope. The
    /// sample rate is the VAD's expected 16 kHz so we hand the pipeline
    /// exactly what `MicPipeline.injectSoakAudio` would otherwise have to
    /// resample.
    private func runInjectLoop() async {
        let samplesPerChunk = Int(injectInterval * 16_000)
        var phase = 0
        while !Task.isCancelled {
            let chunk = Self.synthesizeChunk(samples: samplesPerChunk, startPhase: phase, sampleRate: 16_000)
            phase += samplesPerChunk
            if let mic { await mic.injectSoakAudio(chunk) }
            if let system { await system.injectSoakAudio(chunk) }
            try? await Task.sleep(nanoseconds: UInt64(injectInterval * 1_000_000_000))
        }
    }

    // MARK: Synthetic audio

    /// Public so tests can verify the generator without driving the
    /// harness end-to-end.
    nonisolated static func synthesizeChunk(samples: Int, startPhase: Int, sampleRate: Int = 16_000) -> [Float] {
        // Three carriers at 220 / 330 / 440 Hz. Each carrier is active in
        // a 2 s window with 0.5 s gap, staggered 0.7 s apart so a single
        // "tick" of the soak loop spans multiple overlapping speakers
        // over wall-clock minutes.
        let carriers: [(freq: Double, offset: Double)] = [
            (220.0, 0.0),
            (330.0, 0.7),
            (440.0, 1.4),
        ]
        let amp: Float = 0.15
        var out = [Float](repeating: 0, count: samples)
        for i in 0..<samples {
            let t = Double(startPhase + i) / Double(sampleRate)
            var s: Float = 0
            for c in carriers {
                let cycle = (t - c.offset).truncatingRemainder(dividingBy: 2.5)
                let env: Float = cycle >= 0 && cycle < 2.0 ? 1.0 : 0.0
                if env > 0 {
                    s += amp * Float(sin(2 * .pi * c.freq * t))
                }
            }
            out[i] = s
        }
        return out
    }

    // MARK: Log file

    private func openLog(at now: Date) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: logsFolder, withIntermediateDirectories: true)
        let stamp = Self.fileStampFormatter.string(from: now)
        let url = logsFolder.appendingPathComponent("soak-\(stamp).log", isDirectory: false)
        if !fm.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        self.logHandle = h
        self.logURL = url
    }

    private func writeHeader() {
        let header = "# EarShot soak log — \(ISO8601DateFormatter.soakFormatter.string(from: Date()))\n# columns: ts, resident_mb, cpu_pct, thermal, mic_segments_total, mic_segments_delta, sys_segments_total, sys_segments_delta, echo_dropped_total, echo_dropped_delta, errors_total, errors_delta\n"
        appendLine(header)
    }

    private func appendLine(_ line: String) {
        guard let h = logHandle else { return }
        do {
            try h.seekToEnd()
            try h.write(contentsOf: Data(line.utf8))
            try h.synchronize()
        } catch {
            log.error("Soak log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Read-only convenience for tests.
    func currentLogURL() -> URL? { logURL }

    // MARK: Helpers

    /// Sum of user + system CPU time for the whole process in seconds.
    nonisolated static func processCPUSeconds() -> Double {
        var info = task_thread_times_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
        let sys = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
        // Add terminated-thread time so a long-running process doesn't drift.
        var basic = mach_task_basic_info()
        var bcount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr2 = withUnsafeMutablePointer(to: &basic) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(bcount)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &bcount)
            }
        }
        var deadTotal: Double = 0
        if kr2 == KERN_SUCCESS {
            deadTotal = Double(basic.user_time.seconds) + Double(basic.user_time.microseconds) / 1_000_000
                + Double(basic.system_time.seconds) + Double(basic.system_time.microseconds) / 1_000_000
        }
        return user + sys + deadTotal
    }

    nonisolated static func thermalString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

extension ISO8601DateFormatter {
    static let soakFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

extension SoakHarness {
    /// Filename-safe stamp: yyyyMMdd-HHmmss. ISO8601's colon-bearing form
    /// breaks tools that scan paths with `find … -name`.
    static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
