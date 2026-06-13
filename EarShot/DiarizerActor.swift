//
//  DiarizerActor.swift
//  EarShot
//

import FluidAudio
import Foundation
import os

/// Streaming diarizer for the mic pipeline. Owns a `SortformerDiarizer` and a
/// session-local mapping from its chunk-local speaker slots to human-readable
/// "Speaker N" labels.
///
/// CLAUDE.md architecture rule 1: this is the mic-side diarizer instance. A
/// separate instance lives on the system-audio pipeline when that lands.
/// Architecture rule 3: provisional. Sortformer's tentative segments are read
/// for label lookup so we never block the live ASR finalize on the diarizer's
/// right-context. Architecture rule 8: only the merge layer (or, for now, this
/// actor on the mic side) owns identity assignment.
///
/// Sortformer was picked over LS-EEND for S1 because: 16 kHz input matches the
/// existing mic pipeline (no second resampler), speaker identity is more stable
/// (per vendor-docs/FluidAudio/Diarization/GettingStarted.md), and the 4-slot
/// cap is fine for mic-only conversation. LS-EEND is the right call later when
/// 10+ speakers may appear in call audio.
actor DiarizerActor {
    private let log = Logger(subsystem: "com.earshot.app", category: "DiarizerActor")

    private let diarizer: SortformerDiarizer

    /// Wall-clock time of the first audio sample fed to the diarizer this
    /// session. Diarizer segment timestamps are relative to this moment.
    private var streamEpoch: Date?

    /// Chunk-local diarizer slot index → session-local "Speaker N" number.
    /// New slot ⇒ next available number (1, 2, 3, …). Cleared on `reset()`.
    private var slotToLabel: [Int: Int] = [:]
    private var nextLabel: Int = 1

    /// Last error logged; used to avoid log spam when the diarizer is in a
    /// recurring bad state (e.g. model didn't load).
    private var lastErrorMessage: String?

    init(diarizer: SortformerDiarizer) {
        self.diarizer = diarizer
    }

    /// Convenience factory: download/cache the default Sortformer bundle and
    /// initialize a diarizer with default streaming config. Called from
    /// AppDelegate during mic-pipeline boot.
    static func bootDefault() async throws -> DiarizerActor {
        let models = try await SortformerModels.loadFromHuggingFace(config: .default)
        let diarizer = SortformerDiarizer(config: .default)
        diarizer.initialize(models: models)
        return DiarizerActor(diarizer: diarizer)
    }

    /// Reset all session-local state. Call when the pipeline restarts so slot
    /// numbering does not leak across stream sessions. Keeps the underlying
    /// model loaded.
    func reset() {
        diarizer.reset()
        streamEpoch = nil
        slotToLabel.removeAll(keepingCapacity: true)
        nextLabel = 1
        lastErrorMessage = nil
    }

    /// Push a VAD-sized 16 kHz mono chunk into the streaming diarizer. Caller
    /// must invoke this fire-and-forget from the mic pipeline so the diarizer
    /// never blocks the live VAD/ASR loop.
    func feed(_ samples: [Float], capturedAt: Date) {
        if streamEpoch == nil {
            // Anchor to the wall-clock time of the FIRST sample of the chunk,
            // not now(). Caller passes the moment the chunk left the VAD ring,
            // which is the closest we can get to "sample time".
            streamEpoch = capturedAt
        }
        do {
            _ = try diarizer.process(samples: samples, sourceSampleRate: 16_000)
        } catch {
            let message = error.localizedDescription
            if message != lastErrorMessage {
                log.error("Diarizer process failed: \(message, privacy: .public)")
                lastErrorMessage = message
            }
        }
    }

    /// Look up the dominant Sortformer speaker slot active during
    /// [start, end] and return the matching session-local "Speaker N" label.
    /// Returns nil if the diarizer hasn't observed any overlapping speech (no
    /// fallback label here — callers decide how to render the gap).
    func label(forStart start: Date, end: Date) -> String? {
        guard let epoch = streamEpoch else { return nil }
        let reqStart = Float(start.timeIntervalSince(epoch))
        let reqEnd = Float(end.timeIntervalSince(epoch))
        guard reqEnd > reqStart else { return nil }

        // Per-slot overlap accumulator. Iterate over all known speakers; for
        // each, sum overlap across finalized AND tentative segments — by the
        // time ASR finalizes, the diarizer's right-context may still hold the
        // tail of the utterance as tentative. Rule 3: provisional is fine.
        var overlapBySlot: [Int: Float] = [:]
        for (slotIndex, speaker) in diarizer.timeline.speakers {
            var total: Float = 0
            for segment in speaker.finalizedSegments {
                total += overlap(start: reqStart, end: reqEnd, segStart: segment.startTime, segEnd: segment.endTime)
            }
            for segment in speaker.tentativeSegments {
                total += overlap(start: reqStart, end: reqEnd, segStart: segment.startTime, segEnd: segment.endTime)
            }
            if total > 0 {
                overlapBySlot[slotIndex] = total
            }
        }

        guard let (winningSlot, _) = overlapBySlot.max(by: { $0.value < $1.value }) else {
            return nil
        }

        let number = labelNumber(forSlot: winningSlot)
        return "Speaker \(number)"
    }

    /// Mint or reuse the session-local label number for a chunk-local slot.
    private func labelNumber(forSlot slot: Int) -> Int {
        if let existing = slotToLabel[slot] { return existing }
        let assigned = nextLabel
        slotToLabel[slot] = assigned
        nextLabel += 1
        return assigned
    }

    /// Intersection of two intervals on the real line, clamped to ≥ 0.
    private func overlap(start a: Float, end b: Float, segStart s: Float, segEnd e: Float) -> Float {
        let lo = max(a, s)
        let hi = min(b, e)
        return max(0, hi - lo)
    }
}
