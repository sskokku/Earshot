//
//  TranscriptSearchWindow.swift
//  EarShot
//

import AppKit
import SwiftUI
import os

/// Cross-transcript search window. Queries the FTS5 `segments_fts` virtual
/// table (built and kept in sync since S4) so every segment from every
/// session ever recorded is reachable. The S4 search affordance on the
/// floating panel — query field crammed into the status strip, no filters
/// — is superseded by this window; the panel now only carries a launcher
/// button into it.
///
/// Filters: date range, speaker, source. Each is optional; with all three
/// empty + a non-empty query, the window behaves like the old S4 search.
/// With an empty query + at least one filter set, it behaves like a
/// browse-by-filter view (most-recent-first) so the user can scroll
/// through "every system segment from Bob last week" without typing.
///
/// Clicking a hit opens that day's transcript in `TranscriptReaderWindow`
/// scrolled to the matched segment.
@MainActor
final class TranscriptSearchWindowController {
    private var window: NSWindow?
    private let model: TranscriptSearchModel

    init(model: TranscriptSearchModel) {
        self.model = model
    }

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Task { await model.refreshSpeakers() }
            return
        }

        let host = NSHostingController(rootView: TranscriptSearchWindowView(model: model))
        let win = NSWindow(contentViewController: host)
        win.title = "EarShot Search"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 720, height: 560))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        Task { await model.refreshSpeakers() }
    }
}

/// Single-select wrapper used by the speaker filter Picker. Tags include
/// "any" (nil) and a row per non-merged speaker in the library.
enum SpeakerFilterChoice: Hashable {
    case any
    case speaker(Int64)
}

/// Three-way source filter. `any` translates into "no source constraint";
/// the named cases hit only that pipeline's rows.
enum SourceFilterChoice: Hashable, CaseIterable {
    case any
    case mic
    case system

    var label: String {
        switch self {
        case .any: return "Any"
        case .mic: return "Mic"
        case .system: return "System"
        }
    }

    var asContext: SpeakerLibrary.Context? {
        switch self {
        case .any: return nil
        case .mic: return .mic
        case .system: return .system
        }
    }
}

/// Quick presets that fill the date range pickers in one click. Each maps
/// to a `(start, end)` Date pair anchored on `Date()`; `allTime` clears
/// both bounds.
enum DateRangePreset: String, CaseIterable, Identifiable {
    case allTime = "All time"
    case today = "Today"
    case last7 = "Last 7 days"
    case last30 = "Last 30 days"
    case last90 = "Last 90 days"

    var id: String { rawValue }
}

@MainActor
@Observable
final class TranscriptSearchModel {
    var query: String = ""
    var startDate: Date?
    var endDate: Date?
    var speakerChoice: SpeakerFilterChoice = .any
    var sourceChoice: SourceFilterChoice = .any

    /// Speakers populating the dropdown. Merged-into rows excluded; their
    /// segments were reassigned to the destination on merge.
    var speakers: [SpeakerLibrary.SpeakerRow] = []

    var results: [SpeakerLibrary.SearchHit] = []
    var isSearching: Bool = false
    /// Cap from `searchSegments(limit:)` — surfaced in the UI when the
    /// result set hits the ceiling so the user knows to narrow.
    var hitCeiling: Bool = false
    var lastError: String?

    private let library: SpeakerLibrary
    private let metrics: MetricsCollector
    private let resultLimit: Int = 200
    private let log = Logger(subsystem: "com.earshot.app", category: "TranscriptSearch")

    /// Called when a result is clicked. AppDelegate wires this to open the
    /// in-app transcript reader scrolled to the segment.
    var onOpenHit: (@MainActor (SpeakerLibrary.SearchHit) -> Void)?

    init(library: SpeakerLibrary, metrics: MetricsCollector) {
        self.library = library
        self.metrics = metrics
    }

    func refreshSpeakers() async {
        do {
            let rows = try await library.listSpeakers()
            speakers = rows.filter { $0.mergedInto == nil }
        } catch {
            log.error("Speaker list refresh failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    func applyPreset(_ preset: DateRangePreset) {
        let now = Date()
        switch preset {
        case .allTime:
            startDate = nil
            endDate = nil
        case .today:
            startDate = Calendar.current.startOfDay(for: now)
            endDate = now
        case .last7:
            startDate = Calendar.current.date(byAdding: .day, value: -7, to: now)
            endDate = now
        case .last30:
            startDate = Calendar.current.date(byAdding: .day, value: -30, to: now)
            endDate = now
        case .last90:
            startDate = Calendar.current.date(byAdding: .day, value: -90, to: now)
            endDate = now
        }
    }

    func runSearch() async {
        guard !isSearching else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filters = currentFilters()
        let hasFilters = (filters.startDate != nil)
            || (filters.endDate != nil)
            || (filters.speakerIDs?.isEmpty == false)
            || (filters.sources?.isEmpty == false)
        guard !trimmed.isEmpty || hasFilters else {
            results = []
            hitCeiling = false
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let hits = try await library.searchSegments(
                query: trimmed,
                filters: filters,
                limit: resultLimit
            )
            results = hits
            hitCeiling = hits.count >= resultLimit
            // PRD R8 — log every query (empty-query filter-only runs count
            // too, since the user pressed Search). The result count is
            // saturated by the limit, which is acceptable for the future
            // AI-layer decision signal.
            do {
                try await library.logSearch(query: trimmed.isEmpty ? "(filters)" : trimmed, resultCount: hits.count)
                await metrics.recordSearch()
            } catch {
                log.error("Search log write failed: \(error.localizedDescription, privacy: .public)")
            }
        } catch {
            log.error("Search failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            results = []
            hitCeiling = false
        }
    }

    func clearFilters() {
        startDate = nil
        endDate = nil
        speakerChoice = .any
        sourceChoice = .any
    }

    private func currentFilters() -> SpeakerLibrary.SearchFilters {
        var filters = SpeakerLibrary.SearchFilters()
        filters.startDate = startDate
        // If the user picked an end date, push it to the end of that day so
        // a same-day single-pick range catches everything that day.
        if let end = endDate {
            filters.endDate = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end
        }
        switch speakerChoice {
        case .any:
            filters.speakerIDs = nil
        case .speaker(let id):
            filters.speakerIDs = [id]
        }
        if let source = sourceChoice.asContext {
            filters.sources = [source]
        }
        return filters
    }
}

struct TranscriptSearchWindowView: View {
    @Bindable var model: TranscriptSearchModel

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            filtersSection
            resultsSection
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 520)
        .task { await model.refreshSpeakers() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search every transcript", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.runSearch() } }
            Button("Search") {
                Task { await model.runSearch() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isSearching)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .chromeSurface(cornerRadius: 12)
    }

    @ViewBuilder
    private var filtersSection: some View {
        GroupBox("Filters") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("Range")
                        .frame(width: 60, alignment: .leading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DatePicker(
                        "Start",
                        selection: startBinding,
                        displayedComponents: [.date]
                    )
                    .labelsHidden()
                    Text("to")
                        .foregroundStyle(.secondary)
                    DatePicker(
                        "End",
                        selection: endBinding,
                        displayedComponents: [.date]
                    )
                    .labelsHidden()
                    Menu("Quick…") {
                        ForEach(DateRangePreset.allCases) { preset in
                            Button(preset.rawValue) {
                                model.applyPreset(preset)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer()
                    Button("Clear filters") {
                        model.clearFilters()
                    }
                    .controlSize(.small)
                }
                HStack(spacing: 10) {
                    Text("Speaker")
                        .frame(width: 60, alignment: .leading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Speaker", selection: $model.speakerChoice) {
                        Text("Any speaker").tag(SpeakerFilterChoice.any)
                        ForEach(model.speakers) { row in
                            Text(row.displayLabel).tag(SpeakerFilterChoice.speaker(row.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Spacer()
                }
                HStack(spacing: 10) {
                    Text("Source")
                        .frame(width: 60, alignment: .leading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Source", selection: $model.sourceChoice) {
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
    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if model.isSearching {
                    ProgressView().controlSize(.small)
                    Text("Searching…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.results.isEmpty {
                    Text(emptyStateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(model.results.count) result\(model.results.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.hitCeiling {
                        Text("· result limit reached, narrow the query")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.results) { hit in
                        resultRow(hit)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transcriptReadingSurface(cornerRadius: 8)
            if let err = model.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ hit: SpeakerLibrary.SearchHit) -> some View {
        Button {
            model.onOpenHit?(hit)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(hit.dateKey)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                    Text(Self.timeFormatter.string(from: hit.startedAt))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text("[\(hit.source.rawValue)]")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(hit.speakerLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(hit.text)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private var emptyStateText: String {
        let trimmed = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && model.startDate == nil && model.endDate == nil
            && model.speakerChoice == .any && model.sourceChoice == .any {
            return "Type a query or set a filter to search every transcript."
        }
        return "No matches."
    }

    private var startBinding: Binding<Date> {
        Binding(
            get: { model.startDate ?? Date(timeIntervalSinceNow: -7 * 24 * 3600) },
            set: { model.startDate = $0 }
        )
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: { model.endDate ?? Date() },
            set: { model.endDate = $0 }
        )
    }
}
