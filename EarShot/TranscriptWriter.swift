//
//  TranscriptWriter.swift
//  EarShot
//

import Foundation
import os

/// Owns the on-disk daily Markdown transcript.
///
/// CLAUDE.md rule 4 contract: append-only during live operation, each write
/// fully flushed to disk (`fsync`) before returning so a crash mid-write
/// cannot leave half a line. A new file per local-calendar day; the date
/// key is recomputed on every write, which is what gives us both midnight
/// rollover AND "first speech of a new day" rollover in a single check.
///
/// PRD R5 contract: speaker label is carried on the segment itself. The mic
/// pipeline's DiarizerActor (Sortformer, session-local) stamps "Speaker N" on
/// each finalized utterance; we write that verbatim. If the diarizer was not
/// yet warm we fall back to "Speaker ?" rather than silently dropping the
/// label. Source is one of `mic` / `system`. Pause/resume markers land in the
/// same file as plain lines so the transcript stays human-readable without
/// the app. Chunk 5 adds gap markers (battery-sleep wake) and the end-of-day
/// summary block appended by MetricsCollector.
actor TranscriptWriter {
    enum Marker {
        case paused
        case resumed
        /// H1 — written on relaunch after an unclean shutdown (process killed,
        /// crash). The append-only invariant (rule 4) means the file itself
        /// survives; the marker exists so a human reading the transcript can
        /// see where the prior session ended and the new one resumed.
        case crashRecovered
    }

    private let log = Logger(subsystem: "com.earshot.app", category: "TranscriptWriter")

    private var folder: URL
    private var handle: FileHandle?
    private var currentDateKey: String?

    private let dateKeyFormatter: DateFormatter
    private let timeFormatter: DateFormatter

    /// Optional pipe to MetricsCollector so disk-write failures get counted
    /// as the `diskWriteFailure` error class. Wired by AppDelegate.
    private var metrics: MetricsCollector?

    init(folder: URL) {
        self.folder = folder

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "yyyy-MM-dd"
        self.dateKeyFormatter = df

        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.calendar = Calendar(identifier: .gregorian)
        tf.dateFormat = "HH:mm:ss"
        self.timeFormatter = tf
    }

    /// Swap the destination folder. Closes any open handle; the next write
    /// will open a fresh file in the new location. Caller is responsible for
    /// persisting the choice in `AppSettings`.
    func setFolder(_ url: URL) {
        closeHandle()
        folder = url
    }

    func currentFolder() -> URL { folder }

    func setMetrics(_ collector: MetricsCollector) {
        self.metrics = collector
    }

    // MARK: Public writes

    func append(segment: LiveTranscript.Segment) {
        let key = dateKeyFormatter.string(from: segment.startedAt)
        let time = timeFormatter.string(from: segment.startedAt)
        let safeText = sanitize(segment.text)
        let label = segment.speakerLabel ?? "Speaker ?"
        let line = "[\(time)] [\(segment.source.rawValue)] \(label): \(safeText)\n"
        write(line: line, dateKey: key)
    }

    func writeMarker(_ marker: Marker, at date: Date = Date()) {
        let key = dateKeyFormatter.string(from: date)
        let time = timeFormatter.string(from: date)
        let line: String
        switch marker {
        case .paused: line = "paused \(time)\n"
        case .resumed: line = "resumed \(time)\n"
        case .crashRecovered: line = "recovered \(time)\n"
        }
        write(line: line, dateKey: key)
    }

    /// Single-line marker emitted when the system slept on battery and we
    /// missed audio between `start` and `end`. CLAUDE.md long-run survival §
    /// "on battery, allow sleep and write a gap marker on wake".
    func writeGapMarker(from start: Date, to end: Date) {
        let key = dateKeyFormatter.string(from: end)
        let s = timeFormatter.string(from: start)
        let e = timeFormatter.string(from: end)
        let line = "gap \(s) to \(e)\n"
        write(line: line, dateKey: key)
    }

    /// Append the end-of-day MetricsCollector summary block to a specific
    /// day's Markdown. Closes our open handle first if it points at the same
    /// day so the file is in a known state, writes atomically via a fresh
    /// handle, then leaves itself closed — the next live write will reopen
    /// against whatever day the timestamp lands in.
    func appendSummary(_ text: String, dateKey: String) {
        if currentDateKey == dateKey {
            closeHandle()
        }
        let url = folder.appendingPathComponent("\(dateKey).md", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Empty day (app launched but never captured) — skip the summary
            // rather than leaving a header-less file behind.
            return
        }
        do {
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            try h.write(contentsOf: Data(text.utf8))
            try h.synchronize()
            try h.close()
        } catch {
            log.error("Summary append failed: \(error.localizedDescription, privacy: .public)")
            reportDiskError()
        }
    }

    /// Used on clean app shutdown. Live appends do not need this — every
    /// `write` already fsyncs — but releasing the file descriptor lets other
    /// tools open the transcript without contention.
    func close() {
        closeHandle()
    }

    /// S4 — drop the open handle so `SpeakerLibrary.renameSpeaker` /
    /// `mergeSpeakers` can atomically replace the day's file underneath
    /// us. The next live write reopens against whatever file is at the
    /// canonical path, so no explicit resume is needed.
    func pauseForRelabel() {
        closeHandle()
    }

    /// Read-only convenience for tests/diagnostics.
    func transcriptURL(for date: Date) -> URL {
        let key = dateKeyFormatter.string(from: date)
        return folder.appendingPathComponent("\(key).md", isDirectory: false)
    }

    // MARK: Internals

    private func write(line: String, dateKey: String) {
        do {
            try ensureHandle(forDateKey: dateKey)
            guard let handle else { return }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.synchronize()
        } catch {
            // Rule 6: fail quiet on disk hiccups, log. We do NOT throw out of
            // the actor — the live capture loop must not block on disk errors.
            log.error("Transcript write failed: \(error.localizedDescription, privacy: .public)")
            reportDiskError()
            // Drop the handle so the next attempt rebuilds it.
            closeHandle()
        }
    }

    private func reportDiskError() {
        // Detached fire-and-forget hop to the metrics actor. We avoid
        // awaiting here because the live append loop must not block on the
        // metrics serialization point.
        guard let metrics else { return }
        Task { await metrics.recordError(.diskWriteFailure) }
    }

    private func ensureHandle(forDateKey dateKey: String) throws {
        if currentDateKey == dateKey, handle != nil { return }
        closeHandle()

        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let url = folder.appendingPathComponent("\(dateKey).md", isDirectory: false)
        let existed = fm.fileExists(atPath: url.path)

        if !existed {
            // Atomic create. write(to:atomically:) writes to a temp file and
            // renames into place, which guarantees the file exists fully
            // formed even if we crash mid-create.
            let header = "# \(dateKey)\n\n"
            try header.write(to: url, atomically: true, encoding: .utf8)
        }

        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
        currentDateKey = dateKey
    }

    private func closeHandle() {
        if let handle {
            try? handle.synchronize()
            try? handle.close()
        }
        handle = nil
        currentDateKey = nil
    }

    private func sanitize(_ text: String) -> String {
        // Strip embedded newlines so one segment never breaks the line format.
        // The on-disk file must stay machine-parseable with a regex per line.
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
