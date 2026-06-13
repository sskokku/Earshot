# EarShot

A macOS menu bar app that listens continuously, transcribes every voice it can hear (room conversations, Teams / Zoom calls, any app audio), identifies speakers by voice, and remembers them across sessions. **Fully on-device.** Runs for hours without intervention.

## What it does

- **Always-on ambient capture** from the microphone, from the moment you log in.
- **Per-app system audio capture** via Core Audio process taps (macOS 14.4+), for the meeting apps you allow.
- **Two independent pipelines** (mic + system audio), each with its own VAD, ASR, and diarizer, joined only at a merge layer that interleaves finalized segments and dedupes echo.
- **Voice-based speaker identification.** A 30-second enrollment on first launch learns your voice; unknown speakers persist as "Speaker N" until you name them. Naming is retroactive across the day's transcript.
- **Persistent speaker memory.** Cosine similarity against a SQLite-backed embedding store, same-context threshold 0.65, cross-context fallback 0.75. Recognition improves with use.
- **Daily Markdown transcripts** on disk — append-only, fsynced per line, atomic midnight rollover, human-readable.
- **Offline correction pass** every 5 minutes re-resolves provisional speaker labels with better-than-streaming accuracy and rewrites the on-disk transcript atomically. The live panel updates silently.
- **No network calls** except a one-time ~1 GB model download on first run.
- **Audio is ephemeral.** Buffers only; nothing persisted to disk.

## Why it might exist

Existing tools fail on at least one axis:

- **Granola:** meeting-triggered, not always-on; no true voice-based speaker ID; cloud ASR.
- **Teams / Zoom transcription:** only works inside their own calls; speaker labels come from call metadata, not voice.
- **Most "AI notetaker" SaaS:** cloud-based, account-required, opaque retention.

EarShot's bar: always-on + true voice identification + speaker memory + fully local.

## Status

v1 feature-complete pending a live multi-hour soak run. See [`PROGRESS.md`](PROGRESS.md) for chunk-by-chunk implementation history and known limitations.

This is a **personal-use tool** built for one person on one Mac. It is shared publicly in case the architecture is useful to others. Production hardening (auto-updates, App Store submission, multi-user support, cloud sync) is not in scope.

## Important: recording consent

EarShot continuously captures microphone and system audio. **You are solely responsible for complying with all recording, wiretapping, and consent laws in your jurisdiction** — including two-party-consent rules in many U.S. states and many countries. The app shows a first-launch consent gate carrying placeholder legal wording; that wording is a stand-in and has not been reviewed by counsel. Do not rely on it. Read [`EarShot/ConsentGate.swift`](EarShot/ConsentGate.swift) for the current text and treat any legal-grade deployment as your problem to solve.

## Stack

- **Swift 5.10+, SwiftUI**, macOS 14.4+ minimum.
- **[FluidAudio](https://github.com/FluidInference/FluidAudio.git)** — ASR (Parakeet TDT v3), VAD (Silero), diarization (pyannote segmentation + WeSpeaker embeddings + Sortformer streaming).
- **AVAudioEngine** for mic capture.
- **Core Audio process taps** (`CATapDescription` / `kAudioHardwarePropertyTranslatePIDToProcessObject`) for per-app system audio on macOS 14.4+.
- **SQLite via GRDB** for the speaker library and segment index, with **FTS5** porter-stemmed keyword search.
- **Markdown files** on disk for transcripts (the human surface and the source of truth).

## Build

1. macOS 14.4 or later, Xcode 16 or later.
2. `git clone https://github.com/sskokku/Earshot.git && cd Earshot`
3. Open `EarShot.xcodeproj` in Xcode.
4. Set the development team under Signing & Capabilities for each of the three targets (EarShot, EarShotTests, EarShotUITests).
5. Build and run.

On first launch:

- Accept the recording consent gate.
- Grant microphone permission.
- Models (~1 GB) download from HuggingFace via FluidAudio; resume-on-failure is wired.
- Record a 30-second voice sample for owner enrollment.

For per-app system-audio capture (Teams, Zoom, etc.), you'll also need to accept the System Audio Recording prompt the first time the app tries to tap a meeting app. The supported app allowlist is editable in Settings → Audio Sources.

## Architecture

Ten architecture rules are documented in [`CLAUDE.md`](CLAUDE.md). The load-bearing ones:

1. **Two pipelines, never mixed pre-diarization.** Mic and system audio each get their own capture, VAD, ASR, and diarizer.
2. **Nothing accumulates in RAM.** Rolling 30-second buffer per pipeline (5 minutes for the correction pass — a deliberate exception so audio never has to touch disk).
3. **Provisional, then corrected.** Live output may be wrong about speakers; the 5-minute offline pass owns final truth.
4. **The transcript file is the product.** Daily Markdown stays readable even if the app crashes mid-write.
5. **Audio is ephemeral.** No audio persisted to disk, ever.
6. **Fail quiet, recover loud-free.** Route changes, tap detaches, model hiccups: rebuild silently.
7. **Echo dedupe lives in the merge layer.** Token-overlap match within 2 seconds; system copy wins (carries remote speaker identity).
8. **The merge layer owns identity.** Chunk-local diarizer slot IDs are meaningless across chunks; the merge layer maps them to persistent SQLite speaker IDs via embedding match.
9. **Local-only is a contract.** No network calls except the one-time model download.
10. **The live panel is invisible to screen shares.** `NSPanel`, `.nonactivatingPanel`, `sharingType = .none`. Covered by a test.

## Documentation

- [`PRD.md`](PRD.md) — product requirements.
- [`BUILD_PLAN.md`](BUILD_PLAN.md) — five-phase implementation plan with exit tests per phase.
- [`PROGRESS.md`](PROGRESS.md) — chunk-by-chunk decisions, files touched, architecture-rule checks, known limitations.
- [`CLAUDE.md`](CLAUDE.md) — agent operating protocol and architecture rules. Useful if you want to extend the app via Claude Code or a similar agent.

## License

MIT. See [`LICENSE`](LICENSE).

## Acknowledgments

EarShot stands on:

- **[FluidAudio](https://github.com/FluidInference/FluidAudio)** by FluidInference — Parakeet ASR, Silero VAD, pyannote + WeSpeaker + Sortformer diarization, all packaged for Swift.
- **[GRDB](https://github.com/groue/GRDB.swift)** by Gwendal Roué — SQLite for Swift, including the FTS5 integration that powers keyword search.
