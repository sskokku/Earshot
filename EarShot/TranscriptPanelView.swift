//
//  TranscriptPanelView.swift
//  EarShot
//

import SwiftUI

/// Actions the panel can ask the app to perform. Closures so the
/// panel stays decoupled from AppDelegate. All callbacks are
/// fire-and-forget — results land back in `appState` / `LiveTranscript`
/// asynchronously.
@MainActor
struct PanelActions {
    /// Open the rename sheet for the speaker on this segment. Caller
    /// resolves the speakerID + current display label and runs the
    /// transactional rename via SpeakerLibrary.
    var renameSpeaker: (LiveTranscript.Segment) -> Void
    /// Open the cross-transcript search window. The panel-embedded search
    /// strip from S4 is gone; the magnifying-glass button now launches a
    /// full window with date / speaker / source filters and click-to-open
    /// reader navigation.
    var openTranscriptSearch: () -> Void
    /// Open the speaker library window.
    var openSpeakerLibrary: () -> Void
}

struct TranscriptPanelView: View {
    @Bindable var appState: AppState
    let actions: PanelActions

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusHeader
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .chromeSurface(cornerRadius: 10)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if appState.transcript.segments.isEmpty
                            && appState.transcript.bookmarks.isEmpty
                            && appState.transcript.provisional.isEmpty {
                            placeholder
                        }

                        ForEach(appState.transcript.displayEntries) { entry in
                            switch entry {
                            case .segment(let segment):
                                segmentRow(segment)
                                    .id(entry.id)
                            case .bookmark(let bookmark):
                                bookmarkDivider(bookmark)
                                    .id(entry.id)
                            }
                        }

                        if !appState.transcript.provisional.isEmpty {
                            provisionalRow
                                .id(provisionalAnchorID)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .onChange(of: appState.transcript.segments.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: appState.transcript.bookmarks.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: appState.transcript.provisional) { _, _ in
                    scrollToBottom(proxy)
                }
            }
            .transcriptReadingSurface(cornerRadius: 8)

            if let error = appState.lastErrorMessage, appState.status == .error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minWidth: 320, minHeight: 220)
    }

    private let provisionalAnchorID = "provisional-anchor"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if !appState.transcript.provisional.isEmpty {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(provisionalAnchorID, anchor: .bottom)
            }
        } else if let last = appState.transcript.displayEntries.last {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EarShot is listening.")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Speak and your words will appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func segmentRow(_ segment: LiveTranscript.Segment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(Self.timestampFormatter.string(from: segment.startedAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text("[\(segment.source.rawValue)]")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(segment.speakerLabel ?? "Speaker ?")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
        }
        .contextMenu {
            if segment.speakerID != nil {
                Button(renameMenuTitle(for: segment)) {
                    actions.renameSpeaker(segment)
                }
            }
            Button("Open Speaker Library…") {
                actions.openSpeakerLibrary()
            }
        }
    }

    /// Inline divider for a user-dropped bookmark. Visually distinct
    /// from speaker lines: yellow capsule, bookmark glyph, label first
    /// (the user's intent), timestamp in trailing caption. No source
    /// tag — bookmarks aren't pipeline-attributed.
    private func bookmarkDivider(_ bookmark: LiveTranscript.BookmarkEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark.fill")
                .font(.caption)
                .foregroundStyle(.yellow)
            Text(bookmark.label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Text(Self.timestampFormatter.string(from: bookmark.capturedAt))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.yellow.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.yellow.opacity(0.55), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bookmark: \(bookmark.label) at \(Self.timestampFormatter.string(from: bookmark.capturedAt))")
    }

    private func renameMenuTitle(for segment: LiveTranscript.Segment) -> String {
        let label = segment.speakerLabel ?? "Speaker ?"
        if label.hasPrefix("Speaker ") {
            return "Name \"\(label)\"…"
        }
        return "Rename \"\(label)\"…"
    }

    private var provisionalRow: some View {
        Text(appState.transcript.provisional)
            .font(.body)
            .foregroundStyle(.secondary)
            .italic()
    }

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(appState.status.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: { actions.openSpeakerLibrary() }) {
                Image(systemName: "person.2")
            }
            .buttonStyle(.borderless)
            .help("Speakers")
            Button(action: { actions.openTranscriptSearch() }) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Search transcripts")
        }
    }

    private var statusColor: Color {
        switch appState.status {
        case .idle: return .gray
        case .listening: return .green
        case .paused: return .orange
        case .error: return .red
        }
    }
}
