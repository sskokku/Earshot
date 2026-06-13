//
//  MetricsCollector.swift
//  EarShot
//

import Foundation
import os

/// Single actor every pipeline component reports to (CLAUDE.md "Metrics and
/// errors" §). Holds rollup state for the CURRENT day only — once midnight is
/// crossed, the prior day's stats are flushed to JSON, a human-readable
/// summary block is appended to that day's Markdown, and a fresh day starts.
///
/// Phase 1 captures the PRD R8 subset: uptime, paused time, speech vs silence
/// per pipeline, segments, words, errors by class, recoveries, gap markers,
/// peak resident memory. The Phase 3 fields (speakers, correction relabels,
/// echo dedupe) and Phase 5 fields (avg CPU, thermal events) extend this
/// struct without touching emitter call sites.
actor MetricsCollector {
    enum Pipeline: String, Codable, Sendable {
        case mic, system
    }

    /// One full day's worth of counters. Codable so it round-trips to the
    /// `YYYY-MM-DD.metrics.json` sidecar verbatim. All counters initialize to
    /// zero so the JSON sidecar always lists every error bucket, even at 0 —
    /// makes consuming this file from a script trivial.
    struct DayStats: Codable, Equatable, Sendable {
        let dateKey: String
        var uptimeSeconds: Double = 0
        var pausedSeconds: Double = 0
        var micSpeechSeconds: Double = 0
        var systemSpeechSeconds: Double = 0
        var micSegments: Int = 0
        var systemSegments: Int = 0
        var micWords: Int = 0
        var systemWords: Int = 0
        var errors: [String: Int]
        var recoveries: [String: Int]
        var gapMarkers: Int = 0
        var peakResidentMemoryBytes: UInt64 = 0
        /// PRD R8: "Echo dedupe: duplicates dropped". Incremented by the
        /// MergeLayer each time a mic segment is suppressed because the
        /// system pipeline already had it.
        var echoDropped: Int = 0
        /// PRD R8: "Searches run (gates the future AI layer decision)".
        /// Incremented by AppDelegate.performSearch each time the user
        /// runs an FTS5 query from the floating panel. Persistent search
        /// log lives in `SpeakerLibrary.search_log`.
        var searchesRun: Int = 0
        /// PRD R8 "Correction pass: segments relabeled (proxy for live
        /// diarization accuracy)". Bumped by `CorrectionPass.runOnce`
        /// every time the offline pass picks a different persistent
        /// speaker for a previously-provisional segment.
        var segmentsRelabeled: Int = 0

        init(dateKey: String) {
            self.dateKey = dateKey
            var errs: [String: Int] = [:]
            var recs: [String: Int] = [:]
            for c in ErrorClass.allCases {
                errs[c.rawValue] = 0
                recs[c.rawValue] = 0
            }
            self.errors = errs
            self.recoveries = recs
        }
    }

    private let log = Logger(subsystem: "com.earshot.app", category: "MetricsCollector")
    private let calendar: Calendar
    private let dateKeyFormatter: DateFormatter

    private var folder: URL
    private var currentDay: DayStats

    /// Wall-clock start of the in-progress listening interval (nil while
    /// paused/stopped). Closed out and rolled into `uptimeSeconds` on state
    /// transitions or midnight crossings.
    private var listeningSince: Date?
    private var pausedSince: Date?

    /// Wired by AppDelegate to TranscriptWriter.appendSummary. Sendable so
    /// the detached rollover task can hand off the snapshot safely.
    private var summaryAppender: (@Sendable (String, String) async -> Void)?

    /// H1 — PRD R8 "logged to ~/Earshot/logs/". When wired, every
    /// `recordError` mirrors a line into the daily log file. We do not
    /// mirror every event class (segment counts would explode the log);
    /// errors + recoveries + gap markers + crash recovery are the
    /// forensic-interesting subset.
    private var fileLogger: FileLogger?

    init(folder: URL, now: Date = Date()) {
        self.folder = folder
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = cal

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = cal
        df.dateFormat = "yyyy-MM-dd"
        self.dateKeyFormatter = df

        let key = df.string(from: now)
        self.currentDay = DayStats(dateKey: key)
    }

    // MARK: Configuration

    func setFolder(_ url: URL) { folder = url }
    func currentFolder() -> URL { folder }

    func setSummaryAppender(_ closure: @escaping @Sendable (String, String) async -> Void) {
        summaryAppender = closure
    }

    /// Wire the disk logger so error events get mirrored into
    /// `~/Earshot/logs/earshot-YYYY-MM-DD.log`. Nil-safe: pre-wiring
    /// `recordError` is just a counter bump.
    func setFileLogger(_ logger: FileLogger) {
        self.fileLogger = logger
    }

    // MARK: Listening / paused intervals

    func noteListeningStarted(at date: Date = Date()) {
        rolloverIfNeeded(at: date)
        guard listeningSince == nil else { return }
        if let p = pausedSince {
            currentDay.pausedSeconds += max(0, date.timeIntervalSince(p))
            pausedSince = nil
        }
        listeningSince = date
    }

    func noteListeningStopped(at date: Date = Date()) {
        rolloverIfNeeded(at: date)
        if let s = listeningSince {
            currentDay.uptimeSeconds += max(0, date.timeIntervalSince(s))
            listeningSince = nil
        }
    }

    func notePaused(at date: Date = Date()) {
        rolloverIfNeeded(at: date)
        if let s = listeningSince {
            currentDay.uptimeSeconds += max(0, date.timeIntervalSince(s))
            listeningSince = nil
        }
        if pausedSince == nil { pausedSince = date }
    }

    func noteResumed(at date: Date = Date()) {
        rolloverIfNeeded(at: date)
        if let p = pausedSince {
            currentDay.pausedSeconds += max(0, date.timeIntervalSince(p))
            pausedSince = nil
        }
        if listeningSince == nil { listeningSince = date }
    }

    // MARK: Per-event counters

    func recordSpeech(pipeline: Pipeline, seconds: TimeInterval, at date: Date = Date()) {
        rolloverIfNeeded(at: date)
        let s = max(0, seconds)
        switch pipeline {
        case .mic: currentDay.micSpeechSeconds += s
        case .system: currentDay.systemSpeechSeconds += s
        }
    }

    func recordSegment(pipeline: Pipeline, text: String, at date: Date = Date()) {
        rolloverIfNeeded(at: date)
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        switch pipeline {
        case .mic:
            currentDay.micSegments += 1
            currentDay.micWords += words
        case .system:
            currentDay.systemSegments += 1
            currentDay.systemWords += words
        }
    }

    func recordError(_ kind: ErrorClass, at date: Date = Date()) {
        rolloverIfNeeded(at: date)
        currentDay.errors[kind.rawValue, default: 0] += 1
        if let logger = fileLogger {
            Task { await logger.record(.error, category: "Metrics", message: "error \(kind.rawValue)", at: date) }
        }
    }

    func recordRecoveryAttempt(_ kind: ErrorClass, at date: Date = Date()) {
        rolloverIfNeeded(at: date)
        currentDay.recoveries[kind.rawValue, default: 0] += 1
        if let logger = fileLogger {
            Task { await logger.record(.info, category: "Metrics", message: "recovery attempt \(kind.rawValue)", at: date) }
        }
    }

    func recordGapMarker(at date: Date = Date()) {
        rolloverIfNeeded(at: date)
        currentDay.gapMarkers += 1
        if let logger = fileLogger {
            Task { await logger.record(.info, category: "Metrics", message: "gap marker", at: date) }
        }
    }

    /// PRD R8 / CLAUDE.md rule 7: counts how often the merge layer dropped a
    /// mic segment as an echo of a system segment.
    func recordEchoDropped(at date: Date = Date()) {
        rolloverIfNeeded(at: date)
        currentDay.echoDropped += 1
    }

    /// PRD R8 — every FTS5 query the user runs from the panel is logged
    /// here (and persisted in SpeakerLibrary.search_log). The daily
    /// count feeds the future "is the AI layer worth building?" call.
    func recordSearch(at date: Date = Date()) {
        rolloverIfNeeded(at: date)
        currentDay.searchesRun += 1
    }

    /// PRD R8 "segments relabeled" counter. CorrectionPass calls this
    /// with the count of DB rows whose `speaker_id` changed during a
    /// 5-min pass — `count` may be > 1 because one pass touches many
    /// segments.
    func recordSegmentsRelabeled(count: Int, at date: Date = Date()) {
        rolloverIfNeeded(at: date)
        guard count > 0 else { return }
        currentDay.segmentsRelabeled += count
    }

    func recordMemorySnapshot(bytes: UInt64, at date: Date = Date()) {
        rolloverIfNeeded(at: date)
        if bytes > currentDay.peakResidentMemoryBytes {
            currentDay.peakResidentMemoryBytes = bytes
        }
    }

    /// Force a date-check without recording an event. AppDelegate's periodic
    /// sampler calls this so a silent overnight stretch still rolls over.
    func tick(at date: Date = Date()) {
        rolloverIfNeeded(at: date)
    }

    // MARK: Persistence

    /// Called on pause and on clean shutdown per CLAUDE.md.
    func flush() {
        writeJSON(currentDay)
    }

    /// Clean app quit: close open intervals so trailing seconds aren't lost,
    /// flush JSON, append summary to today's Markdown.
    func finalize(at date: Date = Date()) async {
        rolloverIfNeeded(at: date)
        if let s = listeningSince {
            currentDay.uptimeSeconds += max(0, date.timeIntervalSince(s))
            listeningSince = nil
        }
        if let p = pausedSince {
            currentDay.pausedSeconds += max(0, date.timeIntervalSince(p))
            pausedSince = nil
        }
        writeJSON(currentDay)
        let text = renderSummary(currentDay)
        await summaryAppender?(text, currentDay.dateKey)
    }

    /// Snapshot for tests/diagnostics.
    func snapshot() -> DayStats { currentDay }

    // MARK: Rollover

    private func rolloverIfNeeded(at now: Date) {
        let newKey = dateKeyFormatter.string(from: now)
        guard newKey != currentDay.dateKey else { return }

        // Split open intervals at midnight of the new day so each day owns
        // its share of an interval that straddles the boundary.
        let midnight = calendar.startOfDay(for: now)
        if let s = listeningSince, s < midnight {
            currentDay.uptimeSeconds += midnight.timeIntervalSince(s)
            listeningSince = midnight
        }
        if let p = pausedSince, p < midnight {
            currentDay.pausedSeconds += midnight.timeIntervalSince(p)
            pausedSince = midnight
        }

        // Finalize the prior day. Snapshot is a value-type copy, safe to ship
        // off the actor in a detached task.
        let finished = currentDay
        writeJSON(finished)
        let summary = renderSummary(finished)
        if let appender = summaryAppender {
            Task { await appender(summary, finished.dateKey) }
        }

        currentDay = DayStats(dateKey: newKey)
    }

    private func writeJSON(_ stats: DayStats) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(stats.dateKey).metrics.json", isDirectory: false)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(stats)
            try data.write(to: url, options: .atomic)
        } catch {
            // Disk-write failure here is itself a metrics event — but we are
            // INSIDE the metrics writer and recursing would be silly. Log,
            // drop, and let the next flush succeed.
            log.error("Metrics JSON write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Internal but `nonisolated` so tests can call it on a frozen snapshot.
    nonisolated func renderSummary(_ stats: DayStats) -> String {
        var lines: [String] = []
        lines.append("")
        lines.append("---")
        lines.append("")
        lines.append("## Summary — \(stats.dateKey)")
        lines.append("")
        lines.append("- Uptime: \(Self.formatDuration(stats.uptimeSeconds))")
        lines.append("- Paused: \(Self.formatDuration(stats.pausedSeconds))")
        let micSilence = max(0, stats.uptimeSeconds - stats.micSpeechSeconds)
        lines.append("- Mic speech: \(Self.formatDuration(stats.micSpeechSeconds)) / silence: \(Self.formatDuration(micSilence))")
        if stats.systemSpeechSeconds > 0 {
            let sysSilence = max(0, stats.uptimeSeconds - stats.systemSpeechSeconds)
            lines.append("- System speech: \(Self.formatDuration(stats.systemSpeechSeconds)) / silence: \(Self.formatDuration(sysSilence))")
        }
        let totalSegs = stats.micSegments + stats.systemSegments
        lines.append("- Segments: \(totalSegs) (mic \(stats.micSegments), system \(stats.systemSegments))")
        let totalWords = stats.micWords + stats.systemWords
        lines.append("- Words: \(totalWords) (mic \(stats.micWords), system \(stats.systemWords))")

        let nonZeroErrors = stats.errors.filter { $0.value > 0 }
        if nonZeroErrors.isEmpty {
            lines.append("- Errors: none")
        } else {
            let parts = nonZeroErrors.sorted(by: { $0.key < $1.key }).map { "\($0.key) \($0.value)" }
            lines.append("- Errors: \(parts.joined(separator: ", "))")
        }
        let nonZeroRecoveries = stats.recoveries.filter { $0.value > 0 }
        if !nonZeroRecoveries.isEmpty {
            let parts = nonZeroRecoveries.sorted(by: { $0.key < $1.key }).map { "\($0.key) \($0.value)" }
            lines.append("- Recoveries attempted: \(parts.joined(separator: ", "))")
        }
        lines.append("- Gap markers: \(stats.gapMarkers)")
        lines.append("- Echo dedupe drops: \(stats.echoDropped)")
        lines.append("- Correction relabels: \(stats.segmentsRelabeled)")
        lines.append("- Searches run: \(stats.searchesRun)")
        lines.append("- Peak memory: \(Self.formatMB(stats.peakResidentMemoryBytes))")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    private static func formatMB(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }
}
