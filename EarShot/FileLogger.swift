//
//  FileLogger.swift
//  EarShot
//
//  H1 — PRD R8 says every error "is logged to ~/Earshot/logs/, and counted
//  in metrics." MetricsCollector already counts; this is the disk side.
//
//  The implementation is intentionally tiny:
//  - One actor wrapping a single FileHandle to today's `earshot-YYYY-MM-DD.log`.
//  - One line per event, ISO-8601 timestamp, category, message.
//  - Daily rotation triggered by date key on every write — same pattern as
//    TranscriptWriter. fsync per line so a crash mid-write doesn't lose the
//    last error before it.
//  - Retention is a fixed window (default 30 days). Pruning runs on `start()`
//    and again on every date rollover.
//
//  This is not a replacement for `os.Logger`. The OS unified log stays the
//  source of truth for live debugging in Console.app; this file logger is
//  the persistent forensic record per PRD R8.
//

import Foundation
import os

actor FileLogger {
    enum Level: String, Sendable {
        case info
        case warning
        case error
    }

    private let log = Logger(subsystem: "com.earshot.app", category: "FileLogger")

    private var folder: URL
    private var handle: FileHandle?
    private var currentDateKey: String?

    private let dateKeyFormatter: DateFormatter
    private let timestampFormatter: ISO8601DateFormatter

    /// H1 retention window. CLAUDE.md doesn't pick a number; 30 days is the
    /// same shape as the transcript retention setting in PRD R5 ("rolling
    /// window 30/90 days"). Configurable so tests can override.
    var retentionDays: Int

    init(folder: URL, retentionDays: Int = 30) {
        self.folder = folder
        self.retentionDays = retentionDays

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "yyyy-MM-dd"
        self.dateKeyFormatter = df

        let ts = ISO8601DateFormatter()
        ts.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestampFormatter = ts
    }

    // MARK: Public

    func setFolder(_ url: URL) {
        closeHandle()
        folder = url
    }

    func currentFolder() -> URL { folder }

    /// Write one event line. The caller is `MetricsCollector.recordError`
    /// today; future error sites can call this directly without going
    /// through metrics. Failures are logged via `os.Logger` and swallowed:
    /// the file logger must never throw out into the live pipeline.
    func record(_ level: Level, category: String, message: String, at date: Date = Date()) {
        let key = dateKeyFormatter.string(from: date)
        let ts = timestampFormatter.string(from: date)
        let line = "\(ts) [\(level.rawValue.uppercased())] [\(category)] \(message)\n"
        do {
            try ensureHandle(forDateKey: key)
            guard let handle else { return }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.synchronize()
        } catch {
            log.error("FileLogger write failed: \(error.localizedDescription, privacy: .public)")
            closeHandle()
        }
    }

    /// Closes the open handle and prunes any log files older than the
    /// retention window. Called by AppDelegate on launch + via the periodic
    /// sampler so a long-running process gets pruned every 30 s of wall
    /// clock without needing a dedicated timer.
    func pruneOldLogs(now: Date = Date()) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 24 * 3600)
        for url in entries {
            // Only manage files we own.
            let name = url.lastPathComponent
            guard name.hasPrefix("earshot-") || name.hasPrefix("soak-") else { continue }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let modified = attrs?[.modificationDate] as? Date ?? Date.distantPast
            if modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Flush + close the active handle. Used on clean shutdown and on
    /// `setFolder`. Live writes do not need this — every write is fsynced.
    func close() {
        closeHandle()
    }

    /// Read-only convenience for tests / diagnostics.
    func logURL(for date: Date = Date()) -> URL {
        let key = dateKeyFormatter.string(from: date)
        return folder.appendingPathComponent("earshot-\(key).log", isDirectory: false)
    }

    // MARK: Internals

    private func ensureHandle(forDateKey dateKey: String) throws {
        if currentDateKey == dateKey, handle != nil { return }
        closeHandle()

        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("earshot-\(dateKey).log", isDirectory: false)
        if !fm.fileExists(atPath: url.path) {
            // Atomic create — same pattern as TranscriptWriter so an
            // mid-create crash leaves either no file or a header-only file.
            try Data().write(to: url, options: .atomic)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
        currentDateKey = dateKey

        // Opportunistic pruning on rollover so a long-uninterrupted run
        // still trims old files when the date key flips.
        pruneOldLogs()
    }

    private func closeHandle() {
        if let handle {
            try? handle.synchronize()
            try? handle.close()
        }
        handle = nil
        currentDateKey = nil
    }
}
