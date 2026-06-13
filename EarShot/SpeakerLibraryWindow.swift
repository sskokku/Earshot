//
//  SpeakerLibraryWindow.swift
//  EarShot
//

import AppKit
import FluidAudio
import SwiftUI
import os

/// S4 — speaker management window. Lists every speaker in the library
/// with their embedding counts per context, plus per-row actions:
/// rename, merge-into, clear embeddings, delete. The "Me" row also has
/// a "Re-enroll" action that re-runs the 30 s mic capture and replaces
/// the owner's mic-context embeddings (system-context embeddings, e.g.
/// the user's voice as heard through a Teams call on speakers, stay
/// because they were captured independently).
///
/// Naming, merging, re-enrolling, clearing, and deleting all go through
/// `SpeakerLibrary` so the DB writes are transactional with the
/// today's-file relabel where applicable (rename + merge). After every
/// mutation the controller also tells the IdentityResolver to invalidate
/// affected cache entries so the next utterance picks up the new label
/// without a pipeline restart.
@MainActor
final class SpeakerLibraryWindowController {
    private var window: NSWindow?
    private let model: SpeakerLibraryWindowModel

    init(model: SpeakerLibraryWindowModel) {
        self.model = model
    }

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Task { await model.refresh() }
            return
        }

        let host = NSHostingController(rootView: SpeakerLibraryWindowView(model: model))
        let win = NSWindow(contentViewController: host)
        win.title = "EarShot Speakers"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 620, height: 540))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        Task { await model.refresh() }
    }
}

/// Boring view model that owns the speaker list state, runs library
/// mutations, and surfaces errors back into the UI via `lastError`.
@MainActor
@Observable
final class SpeakerLibraryWindowModel {
    var speakers: [SpeakerLibrary.SpeakerRow] = []
    var ownerSpeakerID: Int64? = AppSettings.ownerSpeakerIDValue
    var lastError: String?
    var isReenrolling: Bool = false
    var reenrollmentMessage: String?

    private let log = Logger(subsystem: "com.earshot.app", category: "SpeakerLibraryWindow")

    private let library: SpeakerLibrary
    private let writer: TranscriptWriter
    private let resolver: IdentityResolver?
    private let downloader: ModelDownloader
    private let recorder: EnrollmentRecorder
    private let transcriptFolderProvider: @MainActor () -> URL
    private let onChange: @MainActor () -> Void

    init(
        library: SpeakerLibrary,
        writer: TranscriptWriter,
        resolver: IdentityResolver?,
        downloader: ModelDownloader,
        recorder: EnrollmentRecorder,
        transcriptFolderProvider: @escaping @MainActor () -> URL,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.library = library
        self.writer = writer
        self.resolver = resolver
        self.downloader = downloader
        self.recorder = recorder
        self.transcriptFolderProvider = transcriptFolderProvider
        self.onChange = onChange
    }

    func refresh() async {
        do {
            speakers = try await library.listSpeakers()
            ownerSpeakerID = AppSettings.ownerSpeakerIDValue
        } catch {
            log.error("Speaker list refresh failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    func rename(speakerID: Int64, to newName: String) async {
        do {
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            let outcome = try await library.renameSpeaker(
                speakerID: speakerID,
                newName: trimmed,
                todayDateKey: Self.currentDateKey(),
                transcriptFolder: transcriptFolderProvider(),
                writer: writer
            )
            await resolver?.invalidate(speakerID: speakerID)
            log.info("Renamed speaker=\(speakerID) → \"\(outcome.newLabel, privacy: .public)\" (relabeled \(outcome.relabeledSegmentCount) lines)")
            await refresh()
            onChange()
        } catch {
            log.error("Rename failed for speaker=\(speakerID): \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    func merge(source: Int64, into destination: Int64) async {
        do {
            let outcome = try await library.mergeSpeakers(
                source: source,
                into: destination,
                todayDateKey: Self.currentDateKey(),
                transcriptFolder: transcriptFolderProvider(),
                writer: writer
            )
            await resolver?.invalidate(speakerIDs: [source, destination])
            log.info("Merged speaker=\(source) into speaker=\(destination) (moved \(outcome.movedEmbeddingCount) embeddings, relabeled \(outcome.relabeledSegmentCount) lines)")
            await refresh()
            onChange()
        } catch {
            log.error("Merge failed source=\(source) dest=\(destination): \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    func clearEmbeddings(speakerID: Int64) async {
        do {
            try await library.clearEmbeddings(speakerID: speakerID)
            await resolver?.invalidate(speakerID: speakerID)
            log.info("Cleared embeddings for speaker=\(speakerID)")
            await refresh()
            onChange()
        } catch {
            log.error("Clear embeddings failed for speaker=\(speakerID): \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    func delete(speakerID: Int64) async {
        do {
            try await library.deleteSpeaker(speakerID: speakerID)
            await resolver?.invalidate(speakerID: speakerID)
            log.info("Deleted speaker=\(speakerID)")
            await refresh()
            onChange()
        } catch {
            log.error("Delete failed for speaker=\(speakerID): \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    /// Re-run the 30 s "Me" enrollment. The owner row is created (or
    /// reused) and its mic-context embeddings are replaced atomically.
    /// System-context embeddings (captured from Teams/Zoom calls on
    /// speakers) are left in place because they were captured
    /// independently.
    func reenrollOwner() async {
        guard !isReenrolling else { return }
        isReenrolling = true
        reenrollmentMessage = "Loading diarizer…"
        defer {
            isReenrolling = false
            reenrollmentMessage = nil
        }
        do {
            let loaded = try await downloader.loadAll { [weak self] stage in
                guard let self else { return }
                switch stage {
                case .asr: self.reenrollmentMessage = "Loading ASR…"
                case .diarizer: self.reenrollmentMessage = "Loading diarizer…"
                case .vad: self.reenrollmentMessage = "Loading VAD…"
                }
            }
            let diarizer = DiarizerManager()
            diarizer.initialize(models: loaded.diarizer)

            reenrollmentMessage = "Recording 30 seconds…"
            let samples = try await recorder.record(seconds: 30) { [weak self] remaining in
                self?.reenrollmentMessage = "Recording: \(remaining)s remaining"
            }
            reenrollmentMessage = "Extracting embedding…"
            let embedding = try diarizer.extractSpeakerEmbedding(from: samples)
            guard !embedding.isEmpty else {
                lastError = "Voice embedding came back empty. Try a quieter room."
                return
            }
            let name = AppSettings.ownerName ?? "Me"
            let id = try await library.reenrollOwner(name: name, embedding: embedding)
            await resolver?.invalidate(speakerID: id)
            log.info("Re-enrolled owner speaker=\(id)")
            await refresh()
            onChange()
        } catch {
            log.error("Re-enroll owner failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    private static func currentDateKey(_ date: Date = Date()) -> String {
        AppDelegate.transcriptDateKey(from: date)
    }
}

/// Main window content. Owner section first (with re-enrollment), then
/// the per-speaker list with row actions.
struct SpeakerLibraryWindowView: View {
    @Bindable var model: SpeakerLibraryWindowModel

    @State private var renameSheetTarget: SpeakerLibrary.SpeakerRow?
    @State private var renameDraft: String = ""

    @State private var mergeSheetSource: SpeakerLibrary.SpeakerRow?
    @State private var mergeSheetDestinationID: Int64?

    @State private var confirmDelete: SpeakerLibrary.SpeakerRow?
    @State private var confirmClear: SpeakerLibrary.SpeakerRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Speakers")
                .font(.title2)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .chromeSurface(cornerRadius: 12)

            ownerSection

            Divider()

            List {
                Section("Known speakers") {
                    ForEach(model.speakers.filter { $0.mergedInto == nil && !$0.isOwner }) { row in
                        speakerRow(row)
                    }
                    if model.speakers.filter({ $0.mergedInto == nil && !$0.isOwner }).isEmpty {
                        Text("No other speakers yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                let merged = model.speakers.filter { $0.mergedInto != nil }
                if !merged.isEmpty {
                    Section("Merged") {
                        ForEach(merged) { row in
                            mergedRow(row)
                        }
                    }
                }
            }
            .frame(minHeight: 260)

            if let err = model.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 580, minHeight: 520)
        .task { await model.refresh() }
        .sheet(item: $renameSheetTarget) { row in
            renameSheet(for: row)
        }
        .sheet(item: $mergeSheetSource) { row in
            mergeSheet(for: row)
        }
        .alert("Delete \(confirmDelete?.displayLabel ?? "")?", isPresented: deleteAlertBinding) {
            Button("Delete", role: .destructive) {
                guard let row = confirmDelete else { return }
                Task { await model.delete(speakerID: row.id) }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("This removes the speaker and all their voice embeddings. Segments stay in the transcripts but lose their speaker link.")
        }
        .alert("Clear embeddings for \(confirmClear?.displayLabel ?? "")?", isPresented: clearAlertBinding) {
            Button("Clear", role: .destructive) {
                guard let row = confirmClear else { return }
                Task { await model.clearEmbeddings(speakerID: row.id) }
                confirmClear = nil
            }
            Button("Cancel", role: .cancel) { confirmClear = nil }
        } message: {
            Text("EarShot will forget this voice and re-learn it from the next utterances.")
        }
    }

    // MARK: - Owner section

    @ViewBuilder
    private var ownerSection: some View {
        GroupBox("Me") {
            VStack(alignment: .leading, spacing: 8) {
                if let me = model.speakers.first(where: { $0.isOwner }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(me.displayLabel)
                                .font(.headline)
                            Text("id=\(me.id) · mic embeddings=\(me.micCount) · system embeddings=\(me.systemCount)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Rename…") {
                            renameDraft = me.name ?? me.displayLabel
                            renameSheetTarget = me
                        }
                        Button("Re-enroll…") {
                            Task { await model.reenrollOwner() }
                        }
                        .disabled(model.isReenrolling)
                    }
                } else {
                    Text("Owner not enrolled yet. Finish onboarding to enroll your voice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let msg = model.reenrollmentMessage {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Speaker rows

    @ViewBuilder
    private func speakerRow(_ row: SpeakerLibrary.SpeakerRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayLabel)
                    .font(.body.weight(.medium))
                Text("id=\(row.id) · mic=\(row.micCount) · system=\(row.systemCount)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Rename…") {
                    renameDraft = row.name ?? row.displayLabel
                    renameSheetTarget = row
                }
                Button("Merge into…") {
                    mergeSheetDestinationID = nil
                    mergeSheetSource = row
                }
                Divider()
                Button("Clear embeddings") {
                    confirmClear = row
                }
                Button("Delete speaker", role: .destructive) {
                    confirmDelete = row
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 32)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func mergedRow(_ row: SpeakerLibrary.SpeakerRow) -> some View {
        let into = row.mergedInto ?? 0
        let intoLabel = model.speakers.first { $0.id == into }?.displayLabel ?? "id=\(into)"
        HStack {
            Text(row.displayLabel)
                .font(.body)
                .foregroundStyle(.secondary)
            Text("→ \(intoLabel)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func renameSheet(for row: SpeakerLibrary.SpeakerRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name speaker")
                .font(.headline)
            Text("Currently \"\(row.displayLabel)\".")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitRename(for: row) }
            HStack {
                Spacer()
                Button("Cancel") {
                    renameSheetTarget = nil
                    renameDraft = ""
                }
                Button("Save") { commitRename(for: row) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func commitRename(for row: SpeakerLibrary.SpeakerRow) {
        let draft = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        let speakerID = row.id
        renameSheetTarget = nil
        renameDraft = ""
        Task { await model.rename(speakerID: speakerID, to: draft) }
    }

    @ViewBuilder
    private func mergeSheet(for row: SpeakerLibrary.SpeakerRow) -> some View {
        let candidates = model.speakers.filter { $0.id != row.id && $0.mergedInto == nil }
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge \"\(row.displayLabel)\" into…")
                .font(.headline)
            Text("All embeddings and segments will be reassigned, and today's transcript will be rewritten to use the destination's label. The source row is kept for history but stops appearing in the active list.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Destination", selection: $mergeSheetDestinationID) {
                Text("Select…").tag(Int64?.none)
                ForEach(candidates) { c in
                    Text(c.displayLabel).tag(Int64?.some(c.id))
                }
            }
            .pickerStyle(.menu)
            HStack {
                Spacer()
                Button("Cancel") {
                    mergeSheetSource = nil
                    mergeSheetDestinationID = nil
                }
                Button("Merge") {
                    guard let dest = mergeSheetDestinationID else { return }
                    let sourceID = row.id
                    mergeSheetSource = nil
                    mergeSheetDestinationID = nil
                    Task { await model.merge(source: sourceID, into: dest) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(mergeSheetDestinationID == nil)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { confirmDelete != nil },
            set: { newValue in if !newValue { confirmDelete = nil } }
        )
    }

    private var clearAlertBinding: Binding<Bool> {
        Binding(
            get: { confirmClear != nil },
            set: { newValue in if !newValue { confirmClear = nil } }
        )
    }
}
