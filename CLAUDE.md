# CLAUDE.md - Earshot

## Agent operating protocol (Xcode Claude Agent / Claude Code)
- Work in chunks, never the whole project. One chunk per session. Phase 1 chunk order: (1) app shell + menu bar + floating panel, (2) first-run flow + model download, (3) mic pipeline VAD + ASR to live panel, (4) transcript writer + pause hotkey + markers, (5) metrics skeleton + sleep/route handling.
- Definition of done for every chunk: project compiles, app launches, work committed to git with a descriptive message. Do not start the next chunk in the same session.
- Before any work: read PRD.md and BUILD_PLAN.md, then PROGRESS.md (immediately after CLAUDE.md, before any code action), then `git log --oneline -10` to locate current state. The repo + these docs are the only memory; assume no chat history survives. If PROGRESS.md is missing or disagrees with the code, the code wins — fix PROGRESS.md as part of the current chunk.
- Every chunk ends by updating PROGRESS.md (add/update the chunk's entry, mark ✅ on exit-test pass or ⚠️ with symptoms + suspects if shipping in debug) AND ticking the matching checkbox in BUILD_PLAN.md, in the SAME commit as the code. A chunk is not done until all three (code, PROGRESS.md, BUILD_PLAN.md) move together.
- If approaching usage limits mid-chunk: stop at the nearest compilable state, commit with a WIP message describing exactly what remains, and end the session.
- Ask clarifying questions before starting a chunk if the spec is ambiguous; never improvise on architecture rules below.
- Human-only steps (flag them, do not attempt): signing team, granting macOS permission dialogs, multi-hour soak runs.

## What this is
macOS menu bar app: always-on ambient transcription with voice-based speaker identification and persistent speaker memory. Fully on-device. See PRD.md for requirements, BUILD_PLAN.md for phases.

## Stack (do not substitute without discussion)
- Swift 5.10+, SwiftUI, macOS 14.4+ minimum (Core Audio process taps requirement)
- FluidAudio (Swift Package: https://github.com/FluidInference/FluidAudio.git)
  - ASR: Parakeet TDT v3
  - VAD: Silero
  - Diarization: pyannote segmentation + WeSpeaker embeddings
- AVAudioEngine for mic capture
- Core Audio process taps (CATapDescription / kAudioHardwarePropertyTranslatePIDToProcessObject) for per-app system audio
- SQLite via GRDB for speaker library and segment index
- Markdown files on disk for transcripts (source of truth, human-readable)

## Architecture rules (violating these is a bug, not a style choice)
1. TWO PIPELINES, NEVER MIXED PRE-DIARIZATION. Mic and system audio each get their own capture, VAD, ASR, and diarizer instances. They meet only at the merge layer, which interleaves timestamped finalized segments.
2. NOTHING ACCUMULATES IN RAM. Rolling 30s audio buffer per pipeline, max. Transcript segments flush to disk on finalization. Embeddings are written to SQLite and released. If a collection grows with session length, that is a defect.
3. PROVISIONAL THEN CORRECTED. Live output is allowed to be wrong about speakers. The 5-minute offline correction pass owns final truth and rewrites the on-disk transcript via the segment index. Never let correction block the live path.
4. THE TRANSCRIPT FILE IS THE PRODUCT. Daily Markdown must remain valid and readable even if the app crashes mid-write. Append-only during live; corrections rewrite whole segments atomically (write temp, rename).
5. AUDIO IS EPHEMERAL. No audio persisted to disk, ever. Buffers only.
6. FAIL QUIET, RECOVER LOUD-FREE. Device route changes, tap detach, model hiccups: rebuild and resume silently. Log to ~/Earshot/logs/. Never show a modal during ambient operation.
7. ECHO DEDUPE LIVES IN THE MERGE LAYER. Mic segment whose normalized text closely matches a system segment within a 2s window is dropped; the system copy wins (it carries the correct remote speaker). Match on normalized token overlap, not exact string.
8. THE MERGE LAYER OWNS IDENTITY. Streaming diarizers emit chunk-local speaker IDs that mean nothing across chunks. The merge layer continuously maps chunk-local IDs to persistent SQLite speaker IDs via embedding match. No other component touches identity.
9. LOCAL-ONLY IS A CONTRACT. No network calls except the one-time model download. Adding any other network call is a breaking change requiring explicit sign-off.
10. THE LIVE PANEL IS INVISIBLE TO SCREEN SHARES. NSPanel, .nonactivatingPanel, window sharingType = .none. Set in the window's initializer, covered by a test that asserts the property.

## Long-run survival checklist (Phase 5 hardens these; respect them from Phase 1)
- ProcessInfo.processInfo.beginActivity(.userInitiated, reason:) to defeat App Nap
- Observe AVAudioEngineConfigurationChange and audio route notifications; tear down and rebuild engine
- Watch thermal state (ProcessInfo.thermalStateDidChangeNotification); under .serious, widen VAD gating and pause the correction pass
- Timer-driven memory self-check in debug builds; assert on growth
- Global pause hotkey (Cmd+Shift+E default) registered via Carbon/NSEvent global monitor; must work when app has no key window
- Sleep assertion (IOPMAssertionCreateWithName, PreventSystemSleep) only while on AC power and listening; on battery, allow sleep and write a gap marker on wake
- LaunchAgent for launch-at-login; first-run model download (~1GB) needs progress UI and resume-on-failure

## Speaker library schema (SQLite)
```sql
CREATE TABLE speakers (
  id INTEGER PRIMARY KEY,
  name TEXT,                 -- NULL until user names them
  created_at TEXT NOT NULL,
  merged_into INTEGER        -- non-NULL if merged into another speaker
);

CREATE TABLE embeddings (
  id INTEGER PRIMARY KEY,
  speaker_id INTEGER NOT NULL REFERENCES speakers(id),
  context TEXT NOT NULL CHECK (context IN ('mic','system')),
  vector BLOB NOT NULL,      -- float32 array from WeSpeaker
  quality REAL,              -- duration/SNR-derived confidence
  created_at TEXT NOT NULL
);

CREATE TABLE segments (
  id INTEGER PRIMARY KEY,
  date TEXT NOT NULL,        -- YYYY-MM-DD, keys the transcript file
  start_ts REAL NOT NULL,    -- unix epoch
  end_ts REAL NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('mic','system')),
  session_id TEXT NOT NULL,  -- ambient block or call block id
  speaker_id INTEGER REFERENCES speakers(id),
  provisional INTEGER NOT NULL DEFAULT 1,
  text TEXT NOT NULL
);
```

## Matching policy
- New embedding vs library: cosine similarity, same-context threshold 0.65, cross-context fallback 0.75 (tune empirically; start here).
- Below both thresholds: create new speaker, label "Speaker N".
- Keep at most 10 embeddings per speaker per context; replace lowest-quality on overflow.

## Metrics and errors
- Single MetricsCollector actor; every pipeline and the merge layer report events to it. Flushed to YYYY-MM-DD.metrics.json on rollover, pause, and clean quit; summary block appended to the day's Markdown at rollover.
- Error taxonomy (enum, exhaustive): routeChange, tapDetach, asrFailure, diarizerFailure, diskWriteFailure, modelLoadFailure. Every catch site maps to one. Unknown errors are a compile-time smell; extend the enum instead.
- Recovery attempts are themselves counted. Glyph error state only after N consecutive failed recoveries (start N=3).
- Speaker naming must be transactional: retroactive file relabel + embedding reassignment + segment table update commit together or not at all.

## Conventions
- A copy of FluidAudio's Documentation folder lives at ./vendor-docs/FluidAudio/. ALWAYS consult these files for exact API signatures before writing FluidAudio integration code. Never guess method names; if a signature is not in the docs, read the package source via SPM checkout.
- Async/await throughout; no Combine for new code.
- Each pipeline is an actor. Merge layer is an actor. UI observes via @Observable view models.
- No third-party deps beyond FluidAudio and GRDB without discussion.
- Tests: unit-test matching policy, merge layer interleaving, and transcript writer atomicity. Audio capture is verified by soak scripts, not unit tests.

## Things already learned (from prior projects, do not relearn)
- ScreenCaptureKit audio capture works but process taps are cleaner for per-app audio on 14.4+; prefer taps.
- AirPods connecting mid-session silently kills a naive AVAudioEngine graph. Route-change handling is not optional.
- macOS will throttle background apps aggressively; the beginActivity assertion matters in practice.
