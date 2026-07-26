import AVFoundation
import OSLog

/// Records audio from the microphone to a buffer
actor AudioRecorder {
    private let logger = OSLog(subsystem: "com.voicetype.audiorecorder", category: "AudioRecorder")

    private var audioEngine: AVAudioEngine?
    private var audioBuffer: [Float] = []
    private let targetSampleRate: Int = 16000
    private var onLevel: (@Sendable (Float) -> Void)?

    /// Initialize the audio recorder
    init() {}

    /// Start recording from the microphone
    /// - Parameter onLevel: called with a normalized (0...1) RMS level for each captured buffer,
    ///   on an unspecified queue — hop to the main actor before touching UI state.
    ///
    /// A fresh `AVAudioEngine` is created for every recording. Reusing one engine across
    /// stop/start cycles intermittently throws an uncaught "format mismatch" exception from
    /// `installTap` (the previously connected/reset node's cached format can go stale), which
    /// crashes the whole app.
    func startRecording(onLevel: (@Sendable (Float) -> Void)? = nil) throws {
        let engine = AVAudioEngine()
        self.audioEngine = engine
        self.onLevel = onLevel

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Clear previous audio
        audioBuffer.removeAll()

        // Attach audio tap to input node to capture audio
        inputNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(format.sampleRate * 0.1), // 100ms buffers
            format: format
        ) { [weak self] buffer, _ in
            Task {
                await self?.processAudioBuffer(buffer)
            }
        }

        // Start the audio engine
        try engine.start()

        os_log("Audio recording started", log: self.logger, type: .info)
    }

    /// Stop recording and return the captured audio samples
    func stopRecording() throws -> [Float] {
        guard let engine = audioEngine else {
            throw AudioRecorderError.engineNotInitialized
        }

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)

        engine.stop()
        engine.reset()
        onLevel = nil
        audioEngine = nil

        os_log("Audio recording stopped, captured %d samples", log: self.logger, type: .info, self.audioBuffer.count)

        return audioBuffer
    }

    /// Process incoming audio buffer and convert to 16kHz mono Float32
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else {
            return
        }

        let frameLength = Int(buffer.frameLength)
        let inputSampleRate = Int(buffer.format.sampleRate)

        // Convert to mono if needed (take first channel)
        let monoSamples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

        if let onLevel {
            var sumOfSquares: Float = 0
            for sample in monoSamples {
                sumOfSquares += sample * sample
            }
            let rms = frameLength > 0 ? sqrt(sumOfSquares / Float(frameLength)) : 0
            // Scale so typical speech volume reads mid-meter; clamp to 0...1.
            let normalized = min(rms * 6, 1.0)
            onLevel(normalized)
        }

        // Resample to 16kHz if needed
        if inputSampleRate == targetSampleRate {
            audioBuffer.append(contentsOf: monoSamples)
        } else {
            let resampledSamples = resample(monoSamples, from: inputSampleRate, to: targetSampleRate)
            audioBuffer.append(contentsOf: resampledSamples)
        }
    }

    /// Simple linear interpolation resampling
    private func resample(_ samples: [Float], from inputRate: Int, to outputRate: Int) -> [Float] {
        let ratio = Double(inputRate) / Double(outputRate)
        let outputCount = Int(Double(samples.count) / ratio)
        var output: [Float] = []
        output.reserveCapacity(outputCount)

        for i in 0..<outputCount {
            let srcIndex = Double(i) * ratio
            let srcIndexInt = Int(srcIndex)
            let fraction = srcIndex - Double(srcIndexInt)

            if srcIndexInt + 1 < samples.count {
                let sample1 = samples[srcIndexInt]
                let sample2 = samples[srcIndexInt + 1]
                let interpolated = sample1 + Float(fraction) * (sample2 - sample1)
                output.append(interpolated)
            } else if srcIndexInt < samples.count {
                output.append(samples[srcIndexInt])
            }
        }

        return output
    }

    /// Cleanup resources
    func cleanup() {
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            engine.reset()
        }
        audioBuffer.removeAll()
    }
}

enum AudioRecorderError: LocalizedError {
    case engineNotInitialized
    case formatNotAvailable
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .engineNotInitialized:
            return "Audio engine not initialized"
        case .formatNotAvailable:
            return "Audio format not available"
        case .recordingFailed(let message):
            return "Recording failed: \(message)"
        }
    }
}
