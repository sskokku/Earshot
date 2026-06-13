//
//  TimelineWindow.swift
//  EarShot
//

import AppKit
import SwiftUI
import os

/// Dedicated NSWindow that renders one day of sessions as a horizontal
/// timeline. Sessions are SQLite-backed (`sessions` + `bookmarks` tables,
/// v4 migration) so this view is a strict read of the persistent model —
/// no live pipeline state. The window also owns curation: a "Redact
/// Range…" sheet that permanently deletes everything inside a chosen
/// `[start, end]` window across the day's Markdown, the `segments`
/// table, the `segments_fts` FTS5 index (cascaded via GRDB-installed
/// triggers), and any bookmarks captured in the same window — all in
/// one `dbQueue.write { … }` so partial state is impossible.
///
/// Click a session block → opens that day's `TranscriptReaderWindow`
/// scrolled to the first segment inside the session's time bounds.
/// Right-click a block → "Redact this session…" pre-fills the sheet
/// with the block's [started_at, ended_at] interval.
@MainActor
final class TimelineWindowController {
    private var window: NSWindow?
    let model: TimelineWindowModel

    init(model: TimelineWindowModel) {
        self.model = model
    }

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Task { await model.reload() }
            return
        }
        let host = NSHostingController(rootView: TimelineWindowView(model: model))
        let win = NSWindow(contentViewController: host)
        win.title = "EarShot Timeline"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 920, height: 460))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        Task { await model.reload() }
    }
}

@MainActor
@Observable
final class TimelineWindowModel {
    /// Visible day. Drives the SQL queries; setting this triggers a
    /// reload via the SwiftUI `.task(id:)` on the view.
    var dateKey: String

    /// Sessions intersecting `dateKey`. Clipped to the day's bounds by
    /// the view; we keep their full extents in the model so the
    /// click-to-reader path can target the session's true start.
    var sessions: [SpeakerLibrary.Session] = []
    var bookmarks: [SpeakerLibrary.Bookmark] = []
    var dayStart: Date = Date()
    var dayEnd: Date = Date()
    var loadError: String?
    var isLoading: Bool = false
    /// Bumps every reload so the view's `task(id:)` re-runs even when
    /// the dateKey hasn't changed (e.g. after a redaction completes).
    var generation: Int = 0

    /// Redaction sheet state. The sheet is modally presented over the
    /// timeline; while it is open, the user has chosen a window and can
    /// preview / confirm. Cleared when the sheet closes.
    var redactionDraft: RedactionDraft?

    /// Hook AppDelegate fills so the timeline can open the in-app
    /// reader when the user clicks a session block.
    var onOpenSession: (@MainActor (SpeakerLibrary.Session) -> Void)?

    let library: SpeakerLibrary
    let writer: TranscriptWriter
    private let log = Logger(subsystem: "com.earshot.app", category: "Timeline")

    init(library: SpeakerLibrary, writer: TranscriptWriter, initialDateKey: String) {
        self.library = library
        self.writer = writer
        self.dateKey = initialDateKey
    }

    func moveDay(by days: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let current = SpeakerLibrary.dayKeyFormatter.date(from: dateKey),
              let next = calendar.date(byAdding: .day, value: days, to: current) else { return }
        dateKey = SpeakerLibrary.dayKeyFormatter.string(from: next)
    }

    func setDate(_ date: Date) {
        dateKey = SpeakerLibrary.dayKeyFormatter.string(from: date)
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let timeline = try await library.timelineForDay(dateKey)
            self.sessions = timeline.sessions
            self.bookmarks = timeline.bookmarks
            self.dayStart = timeline.dayStart
            self.dayEnd = timeline.dayEnd
            self.loadError = nil
            self.generation &+= 1
        } catch {
            log.error("Timeline load failed for \(self.dateKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
            self.loadError = error.localizedDescription
            self.sessions = []
            self.bookmarks = []
        }
    }

    func bookmarks(for session: SpeakerLibrary.Session) -> [SpeakerLibrary.Bookmark] {
        bookmarks.filter { $0.sessionID == session.id }
    }

    /// Begin a curation flow scoped to the full visible day.
    func beginRedactDay() {
        redactionDraft = RedactionDraft(
            start: dayStart,
            end: dayEnd,
            sourceFilter: .any,
            scope: .day(dateKey: dateKey)
        )
    }

    /// Begin a curation flow pre-filled with a specific session's
    /// bounds. Open-ended sessions clip to the day's end.
    func beginRedactSession(_ session: SpeakerLibrary.Session) {
        let s = max(session.startedAt, dayStart)
        let e = min(session.endedAt ?? dayEnd, dayEnd)
        redactionDraft = RedactionDraft(
            start: s,
            end: e,
            sourceFilter: .fromSessionSource(session.source),
            scope: .session(id: session.id, label: sessionDisplayLabel(session))
        )
    }

    func cancelRedaction() {
        redactionDraft = nil
    }

    func sessionDisplayLabel(_ session: SpeakerLibrary.Session) -> String {
        if let label = session.label, !label.isEmpty { return label }
        let kind = session.type == .call ? "Call" : "Ambient"
        let bookmark = bookmarks(for: session).first?.label
        if let bookmark { return "\(kind) — \(bookmark)" }
        return kind
    }
}

/// Live state for the redaction sheet. Carries the chosen window, the
/// source filter, the preview rows (loaded lazily on user click), and
/// the operation outcome once the user confirms.
@MainActor
@Observable
final class RedactionDraft {
    enum Scope: Hashable {
        case day(dateKey: String)
        case session(id: Int64, label: String)
    }

    var start: Date
    var end: Date
    var sourceFilter: SourceFilterChoice
    let scope: Scope

    var previewRows: [SpeakerLibrary.RedactionPreviewRow] = []
    var previewBookmarkCount: Int = 0
    var previewedRange: (start: Date, end: Date, filter: SourceFilterChoice)?
    var isPreviewing: Bool = false
    var isDeleting: Bool = false
    var error: String?
    var lastOutcome: SpeakerLibrary.RedactionOutcome?

    init(start: Date, end: Date, sourceFilter: SourceFilterChoice, scope: Scope) {
        self.start = start
        self.end = end
        self.sourceFilter = sourceFilter
        self.scope = scope
    }

    /// True when the visible (start, end, filter) matches the last
    /// loaded preview. Used to gate the confirm button so the user
    /// cannot redact a window they haven't reviewed.
    var hasFreshPreview: Bool {
        guard let p = previewedRange else { return false }
        return p.start == start && p.end == end && p.filter == sourceFilter
    }

    var sources: Set<SpeakerLibrary.Context>? {
        sourceFilter.sourceSet
    }
}

/// The cross-transcript search window already declares `SourceFilterChoice`
/// with the same three cases (any/mic/system) and a `label`/`asContext`
/// pair. Reuse that type so the picker behavior stays identical across
/// the curation and search surfaces; we just bolt on the two helpers the
/// redaction path needs.
extension SourceFilterChoice {
    /// Translates the filter into the set shape `SpeakerLibrary.redactRange`
    /// expects. `.any` means no filter (every pipeline's segments are in
    /// scope); a named case narrows to a single-element set.
    var sourceSet: Set<SpeakerLibrary.Context>? {
        switch self {
        case .any: return nil
        case .mic: return [.mic]
        case .system: return [.system]
        }
    }

    /// Maps a session row's source onto the filter. `both` sessions
    /// can't be narrowed to one pipeline, so we clear the filter.
    static func fromSessionSource(_ source: SpeakerLibrary.Session.Source) -> SourceFilterChoice {
        switch source {
        case .mic: return .mic
        case .system: return .system
        case .both: return .any
        }
    }
}

// MARK: - View

struct TimelineWindowView: View {
    @Bindable var model: TimelineWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            timeline
            footer
        }
        .padding(16)
        .frame(minWidth: 840, minHeight: 380)
        .task(id: model.dateKey) {
            await model.reload()
        }
        .sheet(isPresented: redactionPresented) {
            if let draft = model.redactionDraft {
                RedactionSheetView(model: model, draft: draft)
            }
        }
    }

    private var redactionPresented: Binding<Bool> {
        Binding(
            get: { model.redactionDraft != nil },
            set: { newValue in
                if !newValue {
                    model.redactionDraft = nil
                }
            }
        )
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
            Button {
                model.moveDay(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .controlSize(.small)
            .keyboardShortcut(.leftArrow, modifiers: [.command])
            DatePicker(
                "Day",
                selection: dayBinding,
                displayedComponents: [.date]
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            Button {
                model.moveDay(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .controlSize(.small)
            .keyboardShortcut(.rightArrow, modifiers: [.command])
            Button("Today") {
                model.setDate(Date())
            }
            .controlSize(.small)
            Spacer()
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Button("Redact Range…") {
                model.beginRedactDay()
            }
            .controlSize(.small)
            Button("Refresh") {
                Task { await model.reload() }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .chromeSurface(cornerRadius: 12)
    }

    @ViewBuilder
    private var timeline: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let blockTop: CGFloat = 28
            let blockHeight: CGFloat = 64
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.05))

                hourTicks(width: width)

                ForEach(model.sessions) { session in
                    sessionBlock(
                        session: session,
                        width: width,
                        top: blockTop,
                        height: blockHeight
                    )
                }

                ForEach(model.bookmarks) { bookmark in
                    bookmarkPin(
                        bookmark: bookmark,
                        width: width,
                        height: blockTop + blockHeight + 18
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minHeight: 160, maxHeight: 200)
    }

    @ViewBuilder
    private func hourTicks(width: CGFloat) -> some View {
        let hours: [Int] = [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24]
        ForEach(hours, id: \.self) { hour in
            let x = CGFloat(hour) / 24.0 * width
            VStack(spacing: 2) {
                Text(hourLabel(hour))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 1, height: 160)
            }
            .frame(width: 36)
            .offset(x: x - 18, y: 0)
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        if hour == 24 { return "24" }
        return String(format: "%02d", hour)
    }

    @ViewBuilder
    private func sessionBlock(
        session: SpeakerLibrary.Session,
        width: CGFloat,
        top: CGFloat,
        height: CGFloat
    ) -> some View {
        let (x, w) = blockGeometry(session: session, width: width)
        let color = blockColor(for: session.source)
        let label = model.sessionDisplayLabel(session)
        Button {
            model.onOpenSession?(session)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(rangeLabel(for: session))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(width: max(28, w), height: height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(0.85))
            )
            .foregroundStyle(.white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: x, y: top)
        .help("\(label) · \(rangeLabel(for: session))")
        .contextMenu {
            Button("Open transcript") {
                model.onOpenSession?(session)
            }
            Divider()
            Button("Redact this session…", role: .destructive) {
                model.beginRedactSession(session)
            }
        }
    }

    private func blockGeometry(
        session: SpeakerLibrary.Session,
        width: CGFloat
    ) -> (x: CGFloat, w: CGFloat) {
        let total = max(1, model.dayEnd.timeIntervalSince(model.dayStart))
        let clampedStart = max(session.startedAt, model.dayStart)
        let endDate = session.endedAt ?? Date()
        let clampedEnd = min(endDate, model.dayEnd)
        let startOffset = clampedStart.timeIntervalSince(model.dayStart)
        let duration = max(60, clampedEnd.timeIntervalSince(clampedStart))
        let x = CGFloat(startOffset / total) * width
        let w = CGFloat(duration / total) * width
        return (x, w)
    }

    private func blockColor(for source: SpeakerLibrary.Session.Source) -> Color {
        switch source {
        case .mic: return Color.teal
        case .system: return Color.orange
        case .both: return Color.purple
        }
    }

    private static let timeRangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private func rangeLabel(for session: SpeakerLibrary.Session) -> String {
        let s = Self.timeRangeFormatter.string(from: session.startedAt)
        let e: String
        if let ended = session.endedAt {
            e = Self.timeRangeFormatter.string(from: ended)
        } else {
            e = "now"
        }
        return "\(s) – \(e)"
    }

    @ViewBuilder
    private func bookmarkPin(
        bookmark: SpeakerLibrary.Bookmark,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let total = max(1, model.dayEnd.timeIntervalSince(model.dayStart))
        let clamped = min(max(bookmark.capturedAt, model.dayStart), model.dayEnd)
        let offset = clamped.timeIntervalSince(model.dayStart)
        let x = CGFloat(offset / total) * width
        VStack(spacing: 0) {
            Image(systemName: "bookmark.fill")
                .font(.caption2)
                .foregroundStyle(.yellow)
            Rectangle()
                .fill(Color.yellow.opacity(0.6))
                .frame(width: 1, height: height - 20)
        }
        .offset(x: x - 4, y: 0)
        .help("\(bookmark.label) · \(Self.timeRangeFormatter.string(from: bookmark.capturedAt))")
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            legendDot(.teal, "Mic")
            legendDot(.orange, "System")
            legendDot(.purple, "Both")
            HStack(spacing: 4) {
                Image(systemName: "bookmark.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                Text("Bookmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.sessions.isEmpty {
                Text("\(model.sessions.count) session\(model.sessions.count == 1 ? "" : "s") · \(model.bookmarks.count) bookmark\(model.bookmarks.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let err = model.loadError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if !model.isLoading {
                Text("No sessions recorded for this day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dayBinding: Binding<Date> {
        Binding(
            get: {
                SpeakerLibrary.dayKeyFormatter.date(from: model.dateKey) ?? Date()
            },
            set: { newValue in
                model.setDate(newValue)
            }
        )
    }
}

// MARK: - Redaction sheet

struct RedactionSheetView: View {
    let model: TimelineWindowModel
    @Bindable var draft: RedactionDraft

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            rangeSection
            previewSection
            actions
        }
        .padding(18)
        .frame(minWidth: 540, minHeight: 420)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
                Text("Redact Transcript")
                    .font(.title3.weight(.semibold))
            }
            Text(scopeDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Removes every matching segment from the Markdown file, the segments table, and the search index in a single transaction. Bookmarks captured in the window are removed too. This cannot be undone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scopeDescription: String {
        switch draft.scope {
        case .day(let dateKey):
            return "Range curation for \(dateKey)"
        case .session(_, let label):
            return "Session: \(label)"
        }
    }

    @ViewBuilder
    private var rangeSection: some View {
        GroupBox("Window") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("From")
                        .frame(width: 50, alignment: .leading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DatePicker(
                        "Start",
                        selection: $draft.start,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                }
                HStack(spacing: 8) {
                    Text("To")
                        .frame(width: 50, alignment: .leading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DatePicker(
                        "End",
                        selection: $draft.end,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                }
                HStack(spacing: 8) {
                    Text("Source")
                        .frame(width: 50, alignment: .leading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Source", selection: $draft.sourceFilter) {
                        ForEach(SourceFilterChoice.allCases, id: \.self) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    Spacer()
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        GroupBox("Preview") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("Preview Affected Segments") {
                        Task { await loadPreview() }
                    }
                    .disabled(draft.isPreviewing || draft.isDeleting)
                    if draft.isPreviewing {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    if draft.hasFreshPreview {
                        Text("\(draft.previewRows.count) segment\(draft.previewRows.count == 1 ? "" : "s") · \(draft.previewBookmarkCount) bookmark\(draft.previewBookmarkCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(draft.previewRows) { row in
                            previewRow(row)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 120, maxHeight: 180)
                .transcriptReadingSurface(cornerRadius: 6)
                if let err = draft.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func previewRow(_ row: SpeakerLibrary.RedactionPreviewRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.timeFormatter.string(from: row.startedAt))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
            Text("[\(row.source.rawValue)]")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)
            Text(row.speakerLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(row.text)
                .font(.caption)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Cancel") {
                model.cancelRedaction()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Delete Permanently") {
                confirmAndDelete()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canDelete)
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    private var canDelete: Bool {
        draft.hasFreshPreview
            && !draft.isDeleting
            && !draft.isPreviewing
            && (draft.previewRows.count > 0 || draft.previewBookmarkCount > 0)
            && draft.start <= draft.end
    }

    private func loadPreview() async {
        guard draft.start <= draft.end else {
            draft.error = "End must be at or after start."
            return
        }
        draft.isPreviewing = true
        draft.error = nil
        defer { draft.isPreviewing = false }
        do {
            let rows = try await model.previewRedaction(
                start: draft.start,
                end: draft.end,
                sources: draft.sources
            )
            let bookmarkCount = try await model.previewBookmarkCount(
                start: draft.start,
                end: draft.end
            )
            draft.previewRows = rows
            draft.previewBookmarkCount = bookmarkCount
            draft.previewedRange = (draft.start, draft.end, draft.sourceFilter)
        } catch {
            draft.error = error.localizedDescription
            draft.previewRows = []
            draft.previewBookmarkCount = 0
            draft.previewedRange = nil
        }
    }

    private func confirmAndDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete \(draft.previewRows.count) segment(s) permanently?"
        alert.informativeText = "This removes the Markdown lines, segments index entries, and \(draft.previewBookmarkCount) bookmark(s) in the window. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Permanently")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        Task {
            await performRedaction()
        }
    }

    private func performRedaction() async {
        draft.isDeleting = true
        defer { draft.isDeleting = false }
        do {
            let outcome = try await model.performRedaction(
                start: draft.start,
                end: draft.end,
                sources: draft.sources
            )
            draft.lastOutcome = outcome
            model.cancelRedaction()
            await model.reload()
            dismiss()
        } catch {
            draft.error = error.localizedDescription
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}

// MARK: - Model bridges

extension TimelineWindowModel {
    func previewRedaction(
        start: Date,
        end: Date,
        sources: Set<SpeakerLibrary.Context>?
    ) async throws -> [SpeakerLibrary.RedactionPreviewRow] {
        try await library.previewRedaction(start: start, end: end, sources: sources)
    }

    func previewBookmarkCount(start: Date, end: Date) async throws -> Int {
        try await library.previewBookmarkRedactionCount(start: start, end: end)
    }

    func performRedaction(
        start: Date,
        end: Date,
        sources: Set<SpeakerLibrary.Context>?
    ) async throws -> SpeakerLibrary.RedactionOutcome {
        try await library.redactRange(
            start: start,
            end: end,
            sources: sources,
            transcriptFolder: AppSettings.transcriptsFolder,
            writer: writer
        )
    }
}
