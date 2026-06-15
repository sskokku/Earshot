//
//  SpeakerCurationWindow.swift
//  EarShot
//

import AppKit
import SwiftUI
import os

/// "Needs Naming" window. Surfaces every active speaker that doesn't
/// have a user-assigned name yet, ranked by total speaking frequency so
/// the user works through the most-impactful labels first. Each row
/// shows a few sample quotes (longest + most-recent) to aid recognition,
/// plus an inline TextField for naming. Below the unnamed list, a
/// "Merge suggestions" section surfaces pairs whose cross-context cosine
/// similarity sits just below the live resolver's auto-merge threshold —
/// the user confirms each with one click.
///
/// Every mutation runs through `SpeakerLibrary` (transactional per
/// CLAUDE.md "transactional speaker naming") and tells the
/// `IdentityResolver` to invalidate cached entries so the live panel
/// picks up the new label on the next utterance.
@MainActor
final class SpeakerCurationWindowController {
    private var window: NSWindow?
    private let model: SpeakerCurationWindowModel

    init(model: SpeakerCurationWindowModel) {
        self.model = model
    }

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Task { await model.refresh() }
            return
        }

        let host = NSHostingController(rootView: SpeakerCurationWindowView(model: model))
        let win = NSWindow(contentViewController: host)
        win.title = "EarShot — Needs Naming"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 720, height: 620))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        Task { await model.refresh() }
    }
}

@MainActor
@Observable
final class SpeakerCurationWindowModel {
    var unnamed: [SpeakerLibrary.UnnamedCurationRow] = []
    var suggestions: [SpeakerLibrary.MergeSuggestion] = []
    /// Resolver score distribution + threshold-sweep aggregate. Pulled
    /// on every `refresh()` (after `unnamed` + `suggestions`) so the
    /// disclosure section in the view reflects the user's most recent
    /// merge decisions without an explicit refetch.
    var stats: SpeakerLibrary.MatchDecisionStats?
    var lastError: String?
    var isRefreshing: Bool = false
    /// Per-row in-flight flag keyed by speaker id so the save button
    /// disables only on the row being committed.
    var inFlightRenames: Set<Int64> = []
    /// Per-pair in-flight flag keyed by suggestion id so two suggestions
    /// can be confirmed back-to-back without interfering.
    var inFlightMerges: Set<String> = []

    private let log = Logger(subsystem: "com.earshot.app", category: "SpeakerCurationWindow")

    private let library: SpeakerLibrary
    private let writer: TranscriptWriter
    private let resolver: IdentityResolver?
    private let transcriptFolderProvider: @MainActor () -> URL
    private let onChange: @MainActor () -> Void

    init(
        library: SpeakerLibrary,
        writer: TranscriptWriter,
        resolver: IdentityResolver?,
        transcriptFolderProvider: @escaping @MainActor () -> URL,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.library = library
        self.writer = writer
        self.resolver = resolver
        self.transcriptFolderProvider = transcriptFolderProvider
        self.onChange = onChange
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let unnamedTask = library.unnamedSpeakersForCuration(quotesPerSpeaker: 3)
            async let suggestionsTask = library.mergeSuggestions(
                minimum: 0.60,
                ceiling: 0.75,
                limit: 10
            )
            async let statsTask = library.matchDecisionStats()
            unnamed = try await unnamedTask
            suggestions = try await suggestionsTask
            stats = try await statsTask
            lastError = nil
        } catch {
            log.error("Curation refresh failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    func commitRename(speakerID: Int64, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !inFlightRenames.contains(speakerID) else { return }
        inFlightRenames.insert(speakerID)
        defer { inFlightRenames.remove(speakerID) }
        do {
            let outcome = try await library.renameSpeaker(
                speakerID: speakerID,
                newName: trimmed,
                todayDateKey: Self.currentDateKey(),
                transcriptFolder: transcriptFolderProvider(),
                writer: writer
            )
            await resolver?.invalidate(speakerID: speakerID)
            log.info("Curation rename speaker=\(speakerID) → \"\(outcome.newLabel, privacy: .public)\" (relabeled \(outcome.relabeledSegmentCount) lines)")
            await refresh()
            onChange()
        } catch {
            log.error("Curation rename failed speaker=\(speakerID): \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    func confirmMerge(suggestion: SpeakerLibrary.MergeSuggestion) async {
        guard !inFlightMerges.contains(suggestion.id) else { return }
        inFlightMerges.insert(suggestion.id)
        defer { inFlightMerges.remove(suggestion.id) }
        do {
            let outcome = try await library.mergeSpeakers(
                source: suggestion.recommendedSource,
                into: suggestion.recommendedDestination,
                todayDateKey: Self.currentDateKey(),
                transcriptFolder: transcriptFolderProvider(),
                writer: writer
            )
            await resolver?.invalidate(speakerIDs: [
                suggestion.recommendedSource,
                suggestion.recommendedDestination
            ])
            log.info("Curation merge \(suggestion.recommendedSource) → \(suggestion.recommendedDestination) (relabeled \(outcome.relabeledSegmentCount), moved \(outcome.movedEmbeddingCount), sim=\(String(format: "%.3f", suggestion.similarity)))")
            await refresh()
            onChange()
        } catch {
            log.error("Curation merge failed pair=\(suggestion.id): \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    private static func currentDateKey(_ date: Date = Date()) -> String {
        AppDelegate.transcriptDateKey(from: date)
    }
}

// MARK: - View

struct SpeakerCurationWindowView: View {
    @Bindable var model: SpeakerCurationWindowModel
    /// Per-row name drafts so each row owns its TextField text without
    /// the model holding a string for every speaker.
    @State private var drafts: [Int64: String] = [:]
    /// DisclosureGroup expansion state for the resolver-stats section.
    /// Collapsed by default so the section doesn't crowd the curation
    /// flow; opens on demand when the user wants to inspect thresholds.
    @State private var statsExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    unnamedSection
                    suggestionsSection
                    statsSection
                }
                .padding(.vertical, 4)
            }

            if let err = model.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 560)
        .task { await model.refresh() }
    }

    // MARK: header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Needs Naming")
                    .font(.title2)
                Spacer()
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            Text(summaryLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chromeSurface(cornerRadius: 12)
    }

    private var summaryLine: String {
        let unnamedCount = model.unnamed.count
        let suggestionCount = model.suggestions.count
        let unnamedPart = "\(unnamedCount) unnamed \(unnamedCount == 1 ? "speaker" : "speakers")"
        let suggestionPart = "\(suggestionCount) merge \(suggestionCount == 1 ? "suggestion" : "suggestions")"
        return "\(unnamedPart) · \(suggestionPart)"
    }

    // MARK: unnamed list

    @ViewBuilder
    private var unnamedSection: some View {
        GroupBox("Speakers without names") {
            if model.unnamed.isEmpty {
                Text("Nothing to name right now. New voices will appear here as EarShot meets them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.unnamed) { row in
                        unnamedRow(row)
                        if row.id != model.unnamed.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private func unnamedRow(_ row: SpeakerLibrary.UnnamedCurationRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.displayLabel)
                    .font(.headline)
                Text(frequencyCaption(row))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if row.sampleQuotes.isEmpty {
                Text("No sample utterances yet — try again after a few finalized segments.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(row.sampleQuotes) { quote in
                        quoteLine(quote)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Name this voice…", text: nameBinding(for: row.id))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveDraft(for: row.id) }
                Button("Save") { saveDraft(for: row.id) }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(
                        model.inFlightRenames.contains(row.id) ||
                        (drafts[row.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    )
            }
        }
        .padding(.vertical, 4)
    }

    private func frequencyCaption(_ row: SpeakerLibrary.UnnamedCurationRow) -> String {
        "id=\(row.id) · segments=\(row.segmentCount) · mic emb=\(row.micEmbeddingCount) · system emb=\(row.systemEmbeddingCount)"
    }

    @ViewBuilder
    private func quoteLine(_ quote: SpeakerLibrary.SampleQuote) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("“")
                .font(.body)
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.text)
                    .font(.body.italic())
                    .textSelection(.enabled)
                    .lineLimit(3)
                Text(quoteMeta(quote))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func quoteMeta(_ quote: SpeakerLibrary.SampleQuote) -> String {
        let timeStr = SpeakerLibrary.timeFormatter.string(from: quote.startedAt)
        let dayStr = SpeakerLibrary.dayKeyFormatter.string(from: quote.startedAt)
        return "[\(dayStr) \(timeStr)] [\(quote.source.rawValue)]"
    }

    private func nameBinding(for speakerID: Int64) -> Binding<String> {
        Binding(
            get: { drafts[speakerID] ?? "" },
            set: { drafts[speakerID] = $0 }
        )
    }

    private func saveDraft(for speakerID: Int64) {
        let raw = drafts[speakerID] ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        drafts[speakerID] = ""
        Task { await model.commitRename(speakerID: speakerID, to: trimmed) }
    }

    // MARK: merge suggestions

    @ViewBuilder
    private var suggestionsSection: some View {
        GroupBox("Merge suggestions") {
            if model.suggestions.isEmpty {
                Text("No merge candidates. Pairs appear here when cross-context similarity sits just below the auto-merge threshold (0.75).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.suggestions) { suggestion in
                        suggestionRow(suggestion)
                        if suggestion.id != model.suggestions.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private func suggestionRow(_ suggestion: SpeakerLibrary.MergeSuggestion) -> some View {
        let destinationLabel: String = (suggestion.recommendedDestination == suggestion.speakerA)
            ? suggestion.speakerALabel
            : suggestion.speakerBLabel
        let sourceLabel: String = (suggestion.recommendedSource == suggestion.speakerA)
            ? suggestion.speakerALabel
            : suggestion.speakerBLabel
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(suggestion.speakerALabel).font(.body.weight(.medium))
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(.secondary)
                    Text(suggestion.speakerBLabel).font(.body.weight(.medium))
                }
                Text("cross-context similarity \(String(format: "%.3f", suggestion.similarity)) · would merge \"\(sourceLabel)\" → \"\(destinationLabel)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Merge") {
                Task { await model.confirmMerge(suggestion: suggestion) }
            }
            .disabled(model.inFlightMerges.contains(suggestion.id))
        }
        .padding(.vertical, 2)
    }

    // MARK: resolver score distribution

    /// Collapsible section that answers "why am I doing all this manual
    /// merge work?" — combines retroactive analysis (works on existing
    /// merges) with prospective decision telemetry (sharper, populates
    /// going forward). Hidden behind a DisclosureGroup so the section
    /// doesn't crowd the curation flow.
    @ViewBuilder
    private var statsSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $statsExpanded) {
                statsBody
            } label: {
                statsHeaderRow
            }
        }
    }

    @ViewBuilder
    private var statsHeaderRow: some View {
        let stats = model.stats
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Resolver score distribution")
                .font(.headline)
            if let s = stats {
                Text(statsSummary(s))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("loading…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func statsSummary(_ s: SpeakerLibrary.MatchDecisionStats) -> String {
        let medSame = s.medianSameContextNearMiss.map { String(format: "%.3f", $0) } ?? "n/a"
        let medCross = s.medianCrossContextNearMiss.map { String(format: "%.3f", $0) } ?? "n/a"
        return "median miss vs correct speaker — same \(medSame) (threshold \(String(format: "%.2f", s.currentSameThreshold))) · cross \(medCross) (threshold \(String(format: "%.2f", s.currentCrossThreshold)))"
    }

    @ViewBuilder
    private var statsBody: some View {
        if let s = model.stats {
            VStack(alignment: .leading, spacing: 12) {
                statsOverviewRow(s)
                Divider()
                statsHistogramRow(s)
                Divider()
                statsSweepTable(s)
                Divider()
                statsClusteringRow(s)
                Text("Near-miss = cosine vs. the correct speaker on past splits the user later merged. Same-context = mic↔mic / system↔system; cross-context = mic↔system. The current thresholds appear in the histograms as red vertical lines.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
        } else {
            Text("Stats unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    @ViewBuilder
    private func statsOverviewRow(_ s: SpeakerLibrary.MatchDecisionStats) -> some View {
        HStack(alignment: .top, spacing: 24) {
            statsKV("Historical merges", "\(s.historicalMergePairCount)")
            statsKV("Live decisions", "\(s.liveDecisionTotal)")
            statsKV("Labeled misses", "\(s.liveLabeledMissTotal) / \(s.liveNoMatchTotal) NO-MATCH")
            Spacer()
        }
    }

    @ViewBuilder
    private func statsKV(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospaced())
        }
    }

    @ViewBuilder
    private func statsHistogramRow(_ s: SpeakerLibrary.MatchDecisionStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Score distribution (near-miss vs. correct speaker)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            histogramBar(title: "same-context", bins: s.sameContextHistogram, threshold: s.currentSameThreshold)
            histogramBar(title: "cross-context", bins: s.crossContextHistogram, threshold: s.currentCrossThreshold)
        }
    }

    @ViewBuilder
    private func histogramBar(title: String, bins: [SpeakerLibrary.MatchDecisionStats.HistogramBin], threshold: Double) -> some View {
        let maxCount = max(1, bins.map(\.count).max() ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let barWidth = totalWidth / CGFloat(bins.count)
                ZStack(alignment: .bottomLeading) {
                    HStack(alignment: .bottom, spacing: 1) {
                        ForEach(bins) { bin in
                            Rectangle()
                                .fill(bin.lowerBound >= threshold ? Color.green.opacity(0.55) : Color.blue.opacity(0.55))
                                .frame(width: max(0, barWidth - 1), height: CGFloat(bin.count) / CGFloat(maxCount) * 56)
                        }
                    }
                    .frame(maxHeight: 56, alignment: .bottom)
                    let thresholdX = CGFloat(threshold) * totalWidth
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 1, height: 56)
                        .offset(x: thresholdX, y: 0)
                }
            }
            .frame(height: 56)
            HStack {
                Text("0.0").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                Spacer()
                Text("0.5").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                Spacer()
                Text("1.0").font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func statsSweepTable(_ s: SpeakerLibrary.MatchDecisionStats) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Threshold sweep — at each candidate gate, past misses caught / wrong-named-merges incurred")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text("threshold").font(.caption2.monospaced()).foregroundStyle(.tertiary).frame(width: 70, alignment: .leading)
                Text("same-ctx TP / FP").font(.caption2.monospaced()).foregroundStyle(.tertiary).frame(width: 130, alignment: .leading)
                Text("cross-ctx TP / FP").font(.caption2.monospaced()).foregroundStyle(.tertiary).frame(width: 130, alignment: .leading)
                Spacer()
            }
            ForEach(s.thresholdSweep) { row in
                let isCurrentSame = abs(row.threshold - s.currentSameThreshold) < 0.001
                let isCurrentCross = abs(row.threshold - s.currentCrossThreshold) < 0.001
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text(String(format: "%.2f", row.threshold))
                            .font(.caption.monospaced())
                        if isCurrentSame {
                            Text("(same)").font(.caption2).foregroundStyle(.red.opacity(0.8))
                        }
                        if isCurrentCross {
                            Text("(cross)").font(.caption2).foregroundStyle(.red.opacity(0.8))
                        }
                    }
                    .frame(width: 70, alignment: .leading)
                    Text("\(row.sameContextTruePositives) / \(row.sameContextFalsePositives)")
                        .font(.caption.monospaced())
                        .frame(width: 130, alignment: .leading)
                    Text("\(row.crossContextTruePositives) / \(row.crossContextFalsePositives)")
                        .font(.caption.monospaced())
                        .frame(width: 130, alignment: .leading)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func statsClusteringRow(_ s: SpeakerLibrary.MatchDecisionStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where misses cluster")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                statsKV("mic misses", "\(s.micMissCount)")
                statsKV("system misses", "\(s.systemMissCount)")
                Spacer()
            }
            if !s.topMissedSpeakers.isEmpty {
                Text("Top missed speakers")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                ForEach(s.topMissedSpeakers) { row in
                    HStack {
                        Text(row.label).font(.caption.monospaced())
                        Spacer()
                        Text("\(row.missCount) miss\(row.missCount == 1 ? "" : "es")")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        if let m = row.medianNearMissScore {
                            Text("median \(String(format: "%.3f", m))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
