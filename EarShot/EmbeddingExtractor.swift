//
//  EmbeddingExtractor.swift
//  EarShot
//

import FluidAudio
import Foundation
import os

/// Shared WeSpeaker embedding extractor. Wraps a single `DiarizerManager`
/// initialized with the pyannote + WeSpeaker bundle so both pipelines can
/// ask for a 256-d Float32 embedding given a span of 16 kHz mono audio.
///
/// Architecture note: CLAUDE.md rule 1 forbids sharing pre-diarization state
/// between pipelines, but embedding extraction is post-diarization (we've
/// already decided this clip belongs to one Sortformer slot) and the
/// `DiarizerManager.extractSpeakerEmbedding` call is stateless across
/// invocations. A single shared extractor saves the ~250 MB of model RAM a
/// second instance would cost.
///
/// Lives as an actor so the underlying non-Sendable manager state stays
/// thread-confined.
actor EmbeddingExtractor {
    private let manager: DiarizerManager
    private let log = Logger(subsystem: "com.earshot.app", category: "EmbeddingExtractor")

    init(manager: DiarizerManager) {
        self.manager = manager
    }

    /// Boots a fresh extractor from the already-downloaded diarizer bundle.
    static func boot() async throws -> EmbeddingExtractor {
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager()
        manager.initialize(models: models)
        return EmbeddingExtractor(manager: manager)
    }

    /// Returns a 256-d L2-normalized embedding for the supplied 16 kHz mono
    /// audio buffer. Returns nil if the clip is too short to extract from
    /// or if the model raises (in which case the failure is logged and
    /// metrics gets a `.diarizerFailure` bump on the caller's side).
    ///
    /// The minimum length check (0.5 s) keeps us from feeding the
    /// segmentation model audio shorter than its receptive field; below
    /// that the embedding is dominated by zero-padding and is worse than
    /// useless.
    func extract(samples: [Float]) -> [Float]? {
        guard samples.count >= 8_000 else { return nil }
        do {
            return try manager.extractSpeakerEmbedding(from: samples)
        } catch {
            log.error("Embedding extraction failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
