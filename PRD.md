# Earshot PRD v1.0

## One-liner
A macOS menu bar app that listens continuously, transcribes every voice it can hear (room conversations, Teams/Zoom calls, any app audio), identifies speakers by voice, and remembers them across sessions. Fully on-device. Runs for hours without intervention.

## Owner
Personal-use tool. Single user, single Mac (Apple Silicon).

## Problem
Existing tools fail on at least one axis:
- Granola: meeting-triggered, not always-on; no true voice-based speaker ID; cloud ASR.
- Teams/Zoom transcription: only works inside their own calls; speaker labels come from call metadata, not voice.
- DayStream (prior build): captured and transcribed but no diarization, no speaker memory, no call auto-attach.

Earshot's bar: always-on + true voice identification + speaker memory + fully local.

## Core requirements

### R1. Always-on ambient capture
- Mic pipeline runs continuously from login. No start/stop per session.
- Voice Activity Detection (Silero via FluidAudio) gates all downstream processing. Silence costs near-zero CPU.
- Survives 10+ hour days: no unbounded memory growth, no App Nap throttling, no crash on audio device changes (AirPods connect/disconnect mid-session must be handled by rebuilding the engine on route change).

### R2. Call auto-attach (non-intrusive)
- Detect when Teams, Zoom, or any app begins producing voice audio.
- Attach a system-audio pipeline via Core Audio process taps (macOS 14.4+). Detach when the app's audio stops.
- Zero user interaction. No prompts, no clicks, no window stealing focus.
- Both pipelines run in parallel during calls: mic hears the user and the room; the tap hears remote participants.
- Per-app allowlist controls which apps' audio is captured. The list is built dynamically from NSWorkspace running applications (apps currently producing audio surfaced first), with a toggle per app, persisted in settings. Default-deny: a new audio-producing app is captured only after the user toggles it on. Media apps (Spotify, Music) stay off so transcripts are not polluted with lyrics and video narration.

### R3. Live transcription
- Streaming ASR via FluidAudio Parakeet TDT v3 (on-device, ANE).
- Live running log in a floating, always-on-top, non-activating panel (NSPanel with .nonactivatingPanel): visible while working in any app, never steals focus, resizable, opacity control, pin/unpin from menu bar.
- The panel's window sharingType is set to none so it is invisible in screen shares and recordings. This is a hard requirement, not a nice-to-have.
- Provisional text appears within ~2s of speech.
- Echo dedupe in the merge layer: when on speakers (not headphones), remote voices are captured by both the tap and the mic. If a mic segment's text closely matches a system segment within a 2s window, the mic copy is dropped and the system copy (correct speaker) wins.
- Transcript flushes to disk continuously. RAM never holds more than a rolling 30s audio buffer per pipeline.

### R4. Speaker identification and memory
- Diarization via FluidAudio (pyannote-based segmentation + WeSpeaker embeddings).
- "Me" enrollment at first run: a 30-second guided voice capture creates the owner's speaker entry, so the most frequent voice in every transcript is named from minute one. Owner embeddings also strengthen echo dedupe.
- Two diarizer instances, one per pipeline. Streams are NEVER mixed before diarization.
- Speaker library persisted in SQLite. Each known speaker holds multiple embeddings tagged by context (mic / system).
- Matching: cosine similarity against library, within-context first, cross-context fallback at a looser threshold.
- Unknown voice: live transcript labels it "Speaker N"; a non-blocking inline affordance lets the user assign a name. Naming triggers two actions: (a) all of today's segments for that speaker are retroactively relabeled in the file, and (b) the speaker's embeddings are permanently filed under the name. From then on, any new voice matching above threshold is auto-labeled, and each match adds a fresh embedding so recognition improves with use. Naming is a one-time event per person per context.
- Manual merge: user can merge two speaker entries (e.g., "Alice (mic)" + "Alice (call)") into one person.

### R5. Transcript output
- One Markdown file per day, filename is the date: YYYY-MM-DD.md
- Storage location is user-chosen in settings (default ~/Earshot/transcripts/, changeable to any folder, including iCloud Drive or an external disk; the app only ever writes files there, no cloud logic of its own).
- Pause/resume continuity: pausing via hotkey writes a "paused HH:MM:SS" marker; resuming writes a "resumed HH:MM:SS" marker and appends to the SAME day's file. App restart mid-day also resumes the same file. A new file starts only when the calendar date changes (rollover at local midnight, or first speech of a new day).
- Segmented into sessions: ambient blocks and call blocks (call blocks tagged with app name and start/end time).
- Line format: `[HH:MM:SS] [source] Speaker Name: text`
- Audio is NOT retained after transcription (rolling buffer only). Transcripts are the artifact.
- LOCAL-ONLY CONTRACT: all data (transcripts, speaker library, settings, logs) lives on this Mac. No cloud storage, no sync, no telemetry. The only network call in the app's lifetime is the one-time model download (~1GB, HuggingFace) at first launch, with a visible progress state. After that the app is fully functional offline.
- Keyword search: SQLite FTS5 index over segments, searchable from the panel. No AI involved. Every search is logged locally; this usage data decides whether an AI layer over transcripts is ever worth building.
- Retention: default keep-forever, with a settings option for a rolling window (30/90 days). FileVault assumed on; transcripts contain sensitive work content.

### R7. Power, session, and control
- Pause hotkey: a global shortcut (default Cmd+Shift+E) instantly pauses ALL capture from any app; the menu bar glyph changes unmistakably. Same shortcut resumes.
- Sleep policy: while listening on AC power, assert against system sleep so capture continues with the lid closed or display off. On battery, allow sleep and write an explicit gap marker to the transcript on wake. User-overridable in settings.
- Launch at login via LaunchAgent, on by default.

### R8. Metrics and error handling
- Every error is handled in code (no silent swallowing), logged to ~/Earshot/logs/, and counted in metrics. Error classes: audio route change, tap detach, ASR inference failure, diarizer failure, disk write failure, model load failure. Recovery is automatic where possible (rule 6 in CLAUDE.md); the menu bar glyph shows a persistent error state only when recovery fails.
- Daily metrics, written two ways: a human-readable summary block appended to the end of each day's Markdown file, and a machine-readable YYYY-MM-DD.metrics.json alongside it.
- Metrics captured per day:
  - Uptime (listening time) and paused time
  - Speech time captured per pipeline (mic / system) vs silence gated by VAD
  - Segments and words transcribed, per pipeline
  - Speakers: distinct speakers heard, new unknowns created, names assigned
  - Correction pass: segments relabeled (proxy for live diarization accuracy)
  - Echo dedupe: duplicates dropped
  - Errors by class, recoveries, gap markers written
  - Peak memory, average CPU, thermal throttle events
  - Searches run (gates the future AI layer decision)
- Metrics are local-only like everything else.

### R6. Accuracy correction
- Live speaker labels are provisional (streaming diarization runs ~10-15% worse DER than offline).
- A background pass every 5 minutes re-diarizes the recent window offline and corrects labels in the on-disk transcript. Live view updates silently.

## Non-goals (v1)
- Overlapping speech separation.
- Automatic cross-context voice matching (manual merge instead).
- AI summaries, action items, or chat over transcripts. Keyword search IS in v1; the AI layer is a separate decision gated on logged search usage after two weeks of real use.
- iOS companion, sync, multi-device, any cloud component.
- Capturing phone calls taken on AirPods paired to a phone (physically impossible from the Mac).

## Success criteria
1. Runs 8 hours unattended; memory stable within +/- 200MB of baseline; no thermal runaway on M-series.
2. A Teams call starting mid-day is captured automatically with remote speech transcribed; nothing required from the user.
3. A person named once is correctly labeled in a session one week later.
4. Word error rate subjectively comparable to Teams live captions on clean speech.
5. Daily transcript file is readable and navigable without the app.

## Key risks
- Streaming diarization mislabels in live view: mitigated by R6 correction pass; accept imperfection in live labels.
- macOS permission friction (mic, screen/audio capture): one-time setup flow with clear instructions.
- Remote voices are codec-compressed; embeddings differ from in-person voices: mitigated by per-context embeddings (R4), not solved.
- OS updates changing Core Audio tap behavior: pin to documented APIs, integration test on OS updates.
