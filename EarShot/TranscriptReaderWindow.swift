//
//  TranscriptReaderWindow.swift
//  EarShot
//

import AppKit
import SwiftUI
import os

/// In-app viewer for a day's transcript Markdown file. Used by the
/// cross-transcript search window so clicking a hit opens that day's
/// transcript scrolled to the matched segment without leaving the app
/// (rule 9 — fully local; we don't shell out to an external editor).
///
/// The on-disk file is the source of truth (rule 4); this window only
/// reads it. The day's writer keeps appending if the date matches
/// today — the reader loads a snapshot; reopening will pick up any new
/// lines. Keeping it read-only avoids a write/race surface against the
/// live `TranscriptWriter`.
@MainActor
final class TranscriptReaderWindowController {
    private var window: NSWindow?
    private let model = TranscriptReaderModel()
    private let log = Logger(subsystem: "com.earshot.app", category: "TranscriptReader")

    /// Open the reader against today's file or a historical one. The
    /// focus tuple matches a single line in the file by its `[HH:MM:SS]`
    /// + source + text triplet (same key the relabel rewriter uses, so
    /// duplicates at the same instant don't cross-target each other).
    func show(transcriptFolder: URL, dateKey: String, focus: TranscriptReaderModel.Focus?) {
        let target = transcriptFolder.appendingPathComponent("\(dateKey).md", isDirectory: false)
        model.load(from: target, dateKey: dateKey, focus: focus)

        if let existing = window {
            existing.title = "EarShot — \(dateKey)"
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: TranscriptReaderWindowView(model: model))
        let win = NSWindow(contentViewController: host)
        win.title = "EarShot — \(dateKey)"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 700, height: 600))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}

@MainActor
@Observable
final class TranscriptReaderModel {
    /// One displayable line. `lineNumber` is a stable id for ScrollViewReader.
    struct Line: Identifiable, Equatable {
        let id: Int
        let text: String
        /// Parsed `[HH:MM:SS]` if this is a canonical segment line. Used
        /// for focus matching.
        let time: String?
        let source: String?
        let label: String?
        let body: String?
        /// Parsed bookmark `(time, label)` if this line is a divider
        /// written by `TranscriptWriter.appendBookmark`. Mutually
        /// exclusive with the canonical-segment fields above.
        let bookmark: BookmarkParsed?
    }

    /// Parse result for a `bookmark HH:MM:SS - LABEL` line in the day's
    /// Markdown. Mirrors the live panel's BookmarkEntry shape so the
    /// reader row can render with the same affordance.
    struct BookmarkParsed: Equatable {
        let time: String
        let label: String
    }

    /// What to scroll to + highlight. Matched against the parsed
    /// (time, source, body) triplet so two lines with identical timestamps
    /// don't cross-target.
    struct Focus: Equatable, Sendable {
        let time: String
        let source: String
        let text: String
    }

    var dateKey: String = ""
    var fileURL: URL?
    var lines: [Line] = []
    var loadError: String?
    var focusedLineID: Int?
    /// Bumps every load so the view's `scrollTo` task knows to re-run.
    var loadGeneration: Int = 0

    private let log = Logger(subsystem: "com.earshot.app", category: "TranscriptReader")

    func load(from url: URL, dateKey: String, focus: Focus?) {
        self.dateKey = dateKey
        self.fileURL = url
        self.loadGeneration &+= 1
        self.focusedLineID = nil
        do {
            let body = try String(contentsOf: url, encoding: .utf8)
            let raw = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var parsed: [Line] = []
            parsed.reserveCapacity(raw.count)
            for (idx, line) in raw.enumerated() {
                if let p = SpeakerLibrary.parseTranscriptLine(line) {
                    parsed.append(Line(
                        id: idx,
                        text: line,
                        time: p.time,
                        source: p.source,
                        label: p.label,
                        body: p.text,
                        bookmark: nil
                    ))
                } else if let b = SpeakerLibrary.parseBookmarkLine(line) {
                    parsed.append(Line(
                        id: idx,
                        text: line,
                        time: nil,
                        source: nil,
                        label: nil,
                        body: nil,
                        bookmark: BookmarkParsed(time: b.time, label: b.label)
                    ))
                } else {
                    parsed.append(Line(id: idx, text: line, time: nil, source: nil, label: nil, body: nil, bookmark: nil))
                }
            }
            self.lines = parsed
            self.loadError = nil

            if let focus {
                focusedLineID = parsed.first { line in
                    line.time == focus.time
                        && line.source == focus.source
                        && (line.body ?? "") == focus.text
                }?.id
                if focusedLineID == nil {
                    // The on-disk file may have been rewritten by the
                    // correction pass between the indexer and our load;
                    // fall back to a time-only match so we still scroll
                    // somewhere useful.
                    focusedLineID = parsed.first { $0.time == focus.time && $0.source == focus.source }?.id
                }
            }
        } catch {
            log.error("Reader load failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            self.lines = []
            self.loadError = error.localizedDescription
        }
    }

    func revealInFinder() {
        guard let url = fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

struct TranscriptReaderWindowView: View {
    @Bindable var model: TranscriptReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .padding(14)
        .frame(minWidth: 600, minHeight: 480)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(model.dateKey)
                .font(.title3.weight(.semibold))
            Spacer()
            Button {
                model.revealInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .controlSize(.small)
            .disabled(model.fileURL == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .chromeSurface(cornerRadius: 10)
    }

    @ViewBuilder
    private var content: some View {
        if let err = model.loadError {
            VStack(alignment: .leading, spacing: 6) {
                Text("Could not open transcript.")
                    .font(.body)
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        } else if model.lines.isEmpty {
            Text("Transcript file is empty.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.lines) { line in
                            row(line)
                                .id(line.id)
                        }
                    }
                    .padding(10)
                }
                .transcriptReadingSurface(cornerRadius: 8)
                .task(id: model.loadGeneration) {
                    guard let target = model.focusedLineID else { return }
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ line: TranscriptReaderModel.Line) -> some View {
        let isFocused = (model.focusedLineID == line.id)
        if let bookmark = line.bookmark {
            bookmarkRow(bookmark, isFocused: isFocused)
        } else {
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isFocused ? Color.yellow.opacity(0.28) : Color.clear)
                )
        }
    }

    @ViewBuilder
    private func bookmarkRow(_ bookmark: TranscriptReaderModel.BookmarkParsed, isFocused: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark.fill")
                .font(.caption)
                .foregroundStyle(.yellow)
            Text(bookmark.label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Text(bookmark.time)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.yellow.opacity(isFocused ? 0.38 : 0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.yellow.opacity(0.55), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bookmark: \(bookmark.label) at \(bookmark.time)")
    }
}
