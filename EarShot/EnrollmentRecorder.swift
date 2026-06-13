//
//  EnrollmentRecorder.swift
//  EarShot
//

import AVFoundation
import FluidAudio
import Foundation

/// Captures a fixed-length burst of microphone audio for "Me" enrollment.
///
/// CLAUDE.md rule 5 (AUDIO IS EPHEMERAL): the captured PCM lives only in memory.
/// Only the resulting 256-d WeSpeaker embedding is persisted.
final class EnrollmentRecorder {
    enum EnrollmentError: LocalizedError {
        case insufficientAudio(captured: Int, expected: Int)
        case engineStartFailed(Error)

        var errorDescription: String? {
            switch self {
            case .insufficientAudio(let captured, let expected):
                let captSec = Double(captured) / 16_000.0
                let expSec = Double(expected) / 16_000.0
                return String(
                    format: "Captured only %.1fs of audio (needed %.1fs). Check that the right input device is selected and try again.",
                    captSec, expSec
                )
            case .engineStartFailed(let error):
                return "Could not start the audio engine: \(error.localizedDescription)"
            }
        }
    }

    /// Thread-safe wrapper that owns the (non-Sendable) AudioConverter and accumulates
    /// resampled samples. The AVAudioEngine tap fires on a non-main thread and captures
    /// only this box, which guards all state with a lock.
    private final class CaptureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        private let converter = AudioConverter()

        func reserve(_ count: Int) {
            lock.lock(); defer { lock.unlock() }
            samples.reserveCapacity(count)
        }

        func ingest(_ buffer: AVAudioPCMBuffer) {
            guard let chunk = try? converter.resampleBuffer(buffer) else { return }
            lock.lock(); defer { lock.unlock() }
            samples.append(contentsOf: chunk)
        }

        func snapshot() -> [Float] {
            lock.lock(); defer { lock.unlock() }
            return samples
        }
    }

    private let engine = AVAudioEngine()

    /// Records `seconds` of microphone audio at 16 kHz mono Float32 and returns the buffer.
    /// `onTick` fires once per remaining second on the main actor.
    @MainActor
    func record(seconds: Int, onTick: @MainActor @escaping (Int) -> Void) async throws -> [Float] {
        let targetSampleCount = 16_000 * seconds
        let box = CaptureBox()
        box.reserve(targetSampleCount + 16_000)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        let tap: AVAudioNodeTapBlock = { buffer, _ in
            box.ingest(buffer)
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: tap)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw EnrollmentError.engineStartFailed(error)
        }

        defer {
            input.removeTap(onBus: 0)
            engine.stop()
        }

        for remaining in stride(from: seconds, through: 0, by: -1) {
            onTick(remaining)
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        let captured = box.snapshot()
        guard captured.count >= targetSampleCount else {
            throw EnrollmentError.insufficientAudio(captured: captured.count, expected: targetSampleCount)
        }
        return Array(captured.prefix(targetSampleCount))
    }
}
