import Foundation
import Testing
import AVFoundation
@testable import Yapboard

@Suite
@MainActor
struct AudioDecoderTests {
    // MARK: - Helper Methods

    func createTempDir() -> URL {
        let tempDirPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirPath, withIntermediateDirectories: true)
        return tempDirPath
    }

    static func createSineWaveAudio(sampleCount: Int, sampleRate: Double, frequency: Float = 440.0) -> [Float] {
        var samples: [Float] = []
        for i in 0..<sampleCount {
            let phase = Float(i) * frequency / Float(sampleRate) * 2.0 * .pi
            let sample = sin(phase) * 0.3
            samples.append(sample)
        }
        return samples
    }

    // MARK: - Tests

    @Test
    func decodeTo16kMono_RoundTripAAC() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a HistoryStore and save audio via addEntry (uses AAC)
        let store = HistoryStore(baseDirectoryOverride: tempDir)
        let originalSamples = Self.createSineWaveAudio(sampleCount: 48000, sampleRate: 16000)

        let entry = store.addEntry(
            rawTranscript: "test",
            polishedTranscript: "Test",
            audioSamples: originalSamples,
            sampleRate: 16000
        )

        // Get the audio URL
        guard let audioURL = store.audioURL(for: entry) else {
            #expect(Bool(false), "Audio URL should exist")
            return
        }

        // Decode the audio back
        let decodedSamples = try AudioDecoder.decodeTo16kMono(fileURL: audioURL)

        // Verify the decoded audio is close to original (within AAC encoding tolerance)
        #expect(decodedSamples.count > 0, "Decoded samples should not be empty")

        // AAC encoding can add some frames; allow ±5000 frame tolerance like the existing test
        let tolerance = 5000
        #expect(
            decodedSamples.count >= originalSamples.count - tolerance && decodedSamples.count <= originalSamples.count + tolerance,
            "Decoded frame count (\(decodedSamples.count)) should be close to original (\(originalSamples.count)), within ±\(tolerance)"
        )

        // Verify RMS energy is preserved (roughly)
        let originalRMS = Self.rmsEnergy(originalSamples)
        let decodedRMS = Self.rmsEnergy(decodedSamples)
        #expect(originalRMS > 0, "Original RMS should be positive")
        #expect(decodedRMS > 0, "Decoded RMS should be positive")
        // Allow ±20% tolerance due to AAC compression artifacts
        let rmsTolerance: Float = 0.2
        let rmsRatio = decodedRMS / originalRMS
        #expect(
            rmsRatio >= (1.0 - rmsTolerance) && rmsRatio <= (1.0 + rmsTolerance),
            "Decoded RMS (\(decodedRMS)) should be close to original RMS (\(originalRMS)), ratio: \(rmsRatio)"
        )
    }

    @Test
    func decodeTo16kMono_Resamples44100HzTo16kHz() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a 44100Hz audio file directly (not through HistoryStore)
        let sourceRate: Double = 44100
        let sourceSampleCount = Int(sourceRate) // 1 second at 44100Hz
        let sourceAudioURL = tempDir.appendingPathComponent("source.caf")

        let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false)!
        let sourceFile = try AVAudioFile(forWriting: sourceAudioURL, settings: sourceFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        let sourceSamples = Self.createSineWaveAudio(sampleCount: sourceSampleCount, sampleRate: sourceRate, frequency: 440.0)
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(sourceSampleCount)) else {
            #expect(Bool(false), "Failed to create source buffer")
            return
        }
        sourceBuffer.frameLength = AVAudioFrameCount(sourceSampleCount)
        sourceSamples.withUnsafeBufferPointer { ptr in
            sourceBuffer.floatChannelData?[0].update(from: ptr.baseAddress!, count: sourceSampleCount)
        }
        try sourceFile.write(from: sourceBuffer)

        // Decode to 16kHz using AudioDecoder
        let decodedSamples = try AudioDecoder.decodeTo16kMono(fileURL: sourceAudioURL)

        // Verify the output is at 16kHz equivalent length
        // 1 second at 44100Hz → 1 second at 16000Hz = 16000 samples
        let expectedFrames = 16000
        let tolerance = 500 // Allow ±500 frames for resampling edge effects

        #expect(
            decodedSamples.count >= expectedFrames - tolerance && decodedSamples.count <= expectedFrames + tolerance,
            "Resampled 1s of 44100Hz audio should yield ~16000 frames at 16kHz, got \(decodedSamples.count)"
        )
    }

    @Test
    func decodeTo16kMono_MissingFileThrows() {
        let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent-\(UUID().uuidString).m4a")

        #expect(throws: NSError.self) {
            try AudioDecoder.decodeTo16kMono(fileURL: missingURL)
        }
    }

    @Test
    func decodeTo16kMono_CorruptFileThrows() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let corruptURL = tempDir.appendingPathComponent("corrupt.m4a")
        try "This is not valid audio data".write(to: corruptURL, atomically: true, encoding: .utf8)

        #expect(throws: NSError.self) {
            try AudioDecoder.decodeTo16kMono(fileURL: corruptURL)
        }
    }

    // MARK: - Helper Utilities

    static func rmsEnergy(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0.0 }
        let sumOfSquares = samples.map { $0 * $0 }.reduce(0, +)
        let mean = sumOfSquares / Float(samples.count)
        return sqrt(mean)
    }
}
