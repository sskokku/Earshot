//
//  ErrorClass.swift
//  EarShot
//

import Foundation

/// CLAUDE.md "Metrics and errors" §: every catch site in the app must map to
/// exactly one of these classes. Adding a new failure mode means extending
/// this enum first, not silently dropping it into `unknown` somewhere.
///
/// Exhaustive `CaseIterable` so the MetricsCollector can zero-initialize a
/// dictionary keyed by every class at day start; that way the JSON sidecar
/// always lists every bucket, even at 0.
enum ErrorClass: String, CaseIterable, Codable, Sendable {
    /// Audio hardware route changed under us (AirPods toggled, USB device
    /// hot-swapped). `AVAudioEngineConfigurationChange` triggers this; the
    /// pipeline tears down and rebuilds.
    case routeChange

    /// A process tap detached unexpectedly (a tapped app quit, lost audio
    /// session). Phase 2 surface, reserved here so every emitter speaks the
    /// same vocabulary from day one.
    case tapDetach

    /// `AsrManager.transcribe` threw. Provisional or final; the whole
    /// utterance is dropped for that call.
    case asrFailure

    /// FluidAudio diarizer threw. Phase 3 surface.
    case diarizerFailure

    /// `FileHandle.write` or `synchronize` failed (disk full, permission
    /// denied, parent folder vanished — e.g. external disk unmounted while
    /// transcribing).
    case diskWriteFailure

    /// `AsrModels.downloadAndLoad` or sibling model bootstrap threw. Boot-time
    /// failure that prevents the pipeline from coming up at all.
    case modelLoadFailure
}
