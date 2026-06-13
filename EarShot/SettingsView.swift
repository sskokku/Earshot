//
//  SettingsView.swift
//  EarShot
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class SettingsModel {
    var transcriptsFolder: URL = AppSettings.transcriptsFolder

    /// Mirrors `SMAppService.mainApp.status` so the toggle reflects the
    /// system's actual state. AppDelegate sets the initial value at launch.
    var launchAtLogin: Bool = false

    /// Invoked after the user picks a new folder so the writer can swap its
    /// destination without an app restart.
    var onFolderChange: ((URL) -> Void)?

    // MARK: Audio sources allowlist

    /// PRD R2 — populated from `AudioSourceCatalog`. Apps producing audio
    /// surface at the top of the list.
    var audioSources: [AudioSourceCatalog.Source] = []

    /// Cached set of enabled bundle IDs so SwiftUI Toggle bindings can read
    /// + write without serializing every refresh through UserDefaults.
    var enabledBundleIDs: Set<String> = SystemAudioAllowlist.enabledBundleIDs()

    func refreshAudioSources() {
        audioSources = AudioSourceCatalog.enumerate()
        enabledBundleIDs = SystemAudioAllowlist.enabledBundleIDs()
    }

    func isAllowed(bundleID: String) -> Bool {
        enabledBundleIDs.contains(bundleID)
    }

    func setAllowed(bundleID: String, allowed: Bool) {
        SystemAudioAllowlist.setEnabled(bundleID: bundleID, enabled: allowed)
        enabledBundleIDs = SystemAudioAllowlist.enabledBundleIDs()
    }

    /// Bridges the toggle to `SMAppService.mainApp`. On failure we revert
    /// `launchAtLogin` so the UI stays consistent with reality (the
    /// LoginItem helper has already logged the underlying error).
    func setLaunchAtLogin(_ on: Bool) {
        let ok = LoginItem.setEnabled(on)
        if ok {
            launchAtLogin = on
        } else {
            launchAtLogin = LoginItem.isEnabled
        }
    }

    func pickFolder(presentingWindow: NSWindow?) {
        let panel = NSOpenPanel()
        panel.title = "Choose transcripts folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = transcriptsFolder

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.transcriptsFolder = url
            AppSettings.transcriptsFolder = url
            self.onFolderChange?(url)
        }

        if let presentingWindow {
            panel.beginSheetModal(for: presentingWindow, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    func revealInFinder() {
        let fm = FileManager.default
        try? fm.createDirectory(at: transcriptsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([transcriptsFolder])
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    weak var hostWindow: NSWindow?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .font(.title2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .chromeSurface(cornerRadius: 12)

                GroupBox("Transcripts") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Daily Markdown files are written here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text(model.transcriptsFolder.path)
                                .font(.callout.monospaced())
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        HStack {
                            Button("Choose Folder…") {
                                model.pickFolder(presentingWindow: hostWindow)
                            }
                            Button("Reveal in Finder") {
                                model.revealInFinder()
                            }
                            Spacer()
                        }
                    }
                    .padding(8)
                }

                AudioSourcesSection(model: model)

                GroupBox("Pause Hotkey") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cmd + Shift + E")
                            .font(.callout.monospaced())
                        Text("Pauses and resumes all capture from any app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Startup") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Launch EarShot at login", isOn: Binding(
                            get: { model.launchAtLogin },
                            set: { model.setLaunchAtLogin($0) }
                        ))
                        Text("Registers EarShot as a system login item so it starts listening automatically each morning.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Power") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Prevents sleep while listening on AC power. On battery, EarShot allows the Mac to sleep and writes a gap marker on wake.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Recording Consent & Disclaimer") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The notice you accepted before EarShot began listening. Re-read at any time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollView {
                            Text(ConsentText.full)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                        .frame(maxHeight: 260)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 560)
    }
}

/// PRD R2 — per-app allowlist UI. Lists currently-running apps with
/// audio-producing apps surfaced first, a toggle per app, persisted via
/// `SystemAudioAllowlist`. Refreshes every 3 s while open so a meeting app
/// that the user just launched appears without a manual reload.
struct AudioSourcesSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        GroupBox("Audio Sources") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose which apps EarShot is allowed to tap. New apps are blocked by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let producing = model.audioSources.filter(\.isProducingAudio)
                let other = model.audioSources.filter { !$0.isProducingAudio }

                if !producing.isEmpty {
                    Text("Currently producing audio")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    VStack(spacing: 0) {
                        ForEach(producing) { source in
                            AudioSourceRow(source: source, model: model)
                        }
                    }
                }

                if !other.isEmpty {
                    Text("Other running apps")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    VStack(spacing: 0) {
                        ForEach(other) { source in
                            AudioSourceRow(source: source, model: model)
                        }
                    }
                }

                if model.audioSources.isEmpty {
                    Text("Scanning running apps…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            // Initial populate then re-poll every 3 s. Cancels automatically
            // when the view goes away. No Combine, no Timer.
            model.refreshAudioSources()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                model.refreshAudioSources()
            }
        }
    }
}

private struct AudioSourceRow: View {
    let source: AudioSourceCatalog.Source
    @Bindable var model: SettingsModel

    var body: some View {
        HStack(spacing: 10) {
            if let icon = AudioSourceCatalog.icon(forBundleID: source.bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(source.displayName)
                    .font(.callout)
                Text(source.bundleID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if source.isProducingAudio {
                Image(systemName: "waveform")
                    .foregroundStyle(.tint)
                    .help("Currently producing audio")
            }
            Toggle("", isOn: Binding(
                get: { model.isAllowed(bundleID: source.bundleID) },
                set: { model.setAllowed(bundleID: source.bundleID, allowed: $0) }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}
