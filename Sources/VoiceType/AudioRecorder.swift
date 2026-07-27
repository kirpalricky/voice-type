import Accelerate
import AVFoundation
import OSLog

/// Records audio from the microphone to a buffer
actor AudioRecorder {
    private let logger = OSLog(subsystem: "com.voicetype.audiorecorder", category: "AudioRecorder")

    private var audioEngine: AVAudioEngine?
    private var audioBuffer: [Float] = []
    private let targetSampleRate: Int = 16000
    private var onBands: (@Sendable ([Float]) -> Void)?
    private var hasReceivedFirstBuffer = false

    // MARK: - Spectrum analysis
    //
    // The level meter needs real per-bar variation, not one scalar fanned out to many bars
    // (that was tried and rejected — every bar being a linear transform of the same value
    // makes them perfectly correlated, so no amount of per-bar smoothing/gain trickery ever
    // produces real shape). A real FFT gives independent per-frequency-band energy instead.
    private let fftSize = 1024
    private let numBands = AppState.barCount
    private var fftSetup: FFTSetup?
    private var hannWindow: [Float] = []
    private var bandLowBin: [Int] = []
    private var bandHighBin: [Int] = []
    private var bandTiltDb: [Float] = []
    private var sampleRateForBands: Double = 0

    // Pre-allocated scratch buffers for computeBands to avoid allocation churn on the audio callback path.
    // Reused across every computeBands call; re-sized if setUpSpectrumAnalysis is called again.
    private var fftWindowed: [Float] = []
    private var fftRealp: [Float] = []
    private var fftImagp: [Float] = []
    private var fftMagnitudes: [Float] = []
    private var bandsMagnitudes: [Float] = []

    /// Persistent one-pole DC-blocking filter state, carried across buffer callbacks (not
    /// reset per-buffer) so the filter stays continuous. Removes mic DC bias and low-frequency
    /// thump — including the cold-start pop AVAudioEngine's tap can produce in its first
    /// buffer(s), which otherwise reads as a visible spike right as recording begins.
    private var dcPrevIn: Float = 0
    private var dcPrevOut: Float = 0

    /// Counts buffer callbacks since the current recording started, so the first few (which
    /// can still carry an engine cold-start transient even after DC-blocking) are dropped
    /// from the meter entirely rather than published as a spike.
    private var buffersSinceStart = 0

    /// Initialize the audio recorder
    init() {}

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    /// Start recording from the microphone
    /// - Parameter onBands: called with `AppState.barCount` normalized (0...1) frequency-band
    ///   magnitudes for each captured buffer, on an unspecified queue — hop to the main actor
    ///   before touching UI state.
    ///
    /// A fresh `AVAudioEngine` is created for every recording. Reusing one engine across
    /// stop/start cycles intermittently throws an uncaught "format mismatch" exception from
    /// `installTap` (the previously connected/reset node's cached format can go stale), which
    /// crashes the whole app.
    func startRecording(onBands: (@Sendable ([Float]) -> Void)? = nil) async throws {
        // The HAL input route can stay cold for well over a second right after app launch
        // (or right after a mic-permission grant), and a from-scratch AVAudioEngine hits
        // that same cold start on every retry — so a single short wait fails the same way
        // every time. Give it a generous wait, and if that still comes up dry, tear down
        // and spin up one more fresh engine before finally giving up.
        for attempt in 0..<2 {
            if try await attemptStartRecording(onBands: onBands) {
                os_log("Audio recording started", log: self.logger, type: .info)
                return
            }
            os_log("Mic delivered no audio on attempt %d, retrying", log: self.logger, type: .error, attempt)
        }
        throw AudioRecorderError.formatNotAvailable
    }

    /// Starts a fresh engine and waits for it to actually deliver audio. Returns `false`
    /// (after cleaning up) if no buffer arrives within the timeout, so the caller can retry.
    private func attemptStartRecording(onBands: (@Sendable ([Float]) -> Void)?) async throws -> Bool {
        let engine = AVAudioEngine()
        self.audioEngine = engine
        self.onBands = onBands
        self.hasReceivedFirstBuffer = false
        self.dcPrevIn = 0
        self.dcPrevOut = 0
        self.buffersSinceStart = 0

        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        setUpSpectrumAnalysis(sampleRate: format.sampleRate)

        // Clear previous audio and pre-allocate for expected max duration (2 min @ 16kHz ~1.9M samples)
        // to avoid repeated reallocation during recording
        audioBuffer.removeAll()
        audioBuffer.reserveCapacity(1_920_000)

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

        var attempts = 0
        while !hasReceivedFirstBuffer && attempts < 40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            attempts += 1
        }
        guard hasReceivedFirstBuffer else {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            self.audioEngine = nil
            self.onBands = nil
            return false
        }

        return true
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
        onBands = nil
        audioEngine = nil

        os_log("Audio recording stopped, captured %d samples", log: self.logger, type: .info, self.audioBuffer.count)

        return audioBuffer
    }

    /// Process incoming audio buffer and convert to 16kHz mono Float32
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else {
            return
        }

        hasReceivedFirstBuffer = true

        let frameLength = Int(buffer.frameLength)
        let inputSampleRate = Int(buffer.format.sampleRate)

        // Convert to mono if needed (take first channel)
        let monoSamples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

        buffersSinceStart += 1
        // AVAudioEngine's tap can produce a cold-start click/pop in its first buffer(s) even
        // after DC-blocking; drop the first few from the meter entirely rather than let that
        // transient show up as a spike right as recording begins. Audio used for
        // transcription below is unaffected.
        if buffersSinceStart > 3, let onBands, let bands = computeBands(from: monoSamples) {
            onBands(bands)
        }

        // Resample to 16kHz if needed
        if inputSampleRate == targetSampleRate {
            audioBuffer.append(contentsOf: monoSamples)
        } else {
            let resampledSamples = resample(monoSamples, from: inputSampleRate, to: targetSampleRate)
            audioBuffer.append(contentsOf: resampledSamples)
        }
    }

    /// Builds the FFT setup, Hann window, and log-spaced band bin ranges once per sample
    /// rate. Log spacing matters specifically for voice: energy piles into the low end, so
    /// linear band spacing would leave only the first few bars ever moving.
    private func setUpSpectrumAnalysis(sampleRate: Double) {
        guard fftSetup == nil || sampleRateForBands != sampleRate else { return }

        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }

        let log2n = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Pre-allocate scratch buffers for computeBands to avoid allocation churn on every audio callback.
        fftWindowed = [Float](repeating: 0, count: fftSize)
        fftRealp = [Float](repeating: 0, count: fftSize / 2)
        fftImagp = [Float](repeating: 0, count: fftSize / 2)
        fftMagnitudes = [Float](repeating: 0, count: fftSize / 2)
        bandsMagnitudes = [Float](repeating: 0, count: numBands)

        sampleRateForBands = sampleRate

        let fMin = 80.0
        // Voice energy is negligible above ~5-6kHz for typical speech (sibilants aside), so
        // keeping the band range up at 8kHz left the top bars mapped to near-silent
        // frequencies that rarely crossed the noise floor — a permanently flat right edge.
        let fMax = min(6400.0, sampleRate / 2)
        let binHz = sampleRate / Double(fftSize)
        let maxBin = fftSize / 2 - 1

        var lowBins: [Int] = []
        var highBins: [Int] = []
        var tiltsDb: [Float] = []
        var previousBin = max(Int(fMin / binHz), 0)

        for band in 1...numBands {
            let freq = fMin * pow(fMax / fMin, Double(band) / Double(numBands))
            let bin = min(max(Int(freq / binHz), previousBin + 1), maxBin)
            lowBins.append(previousBin)
            highBins.append(bin)
            // Rising gain tilt (+7dB/octave above fMin) so higher-frequency consonant energy
            // reads as comparable to the low-frequency fundamental instead of staying dark —
            // voice spectral energy naturally rolls off well above ~4-5kHz, so a smaller
            // tilt wasn't enough to counteract that roll-off and pull top bands above the
            // noise floor. Additive in the dB domain (not a linear multiplier) so it stays a
            // fixed offset regardless of signal level, instead of blowing up loud bands past
            // saturation.
            let octavesAboveMin = log2(freq / fMin)
            tiltsDb.append(Float(6.0 * octavesAboveMin))
            previousBin = bin
        }

        bandLowBin = lowBins
        bandHighBin = highBins
        bandTiltDb = tiltsDb
    }

    /// Runs a real FFT over the most recent `fftSize` samples and bins the magnitude
    /// spectrum into `numBands` log-spaced, gain-compensated bands, each normalized 0...1.
    /// This is what gives each bar genuinely independent data — a single scalar level fanned
    /// out to many bars (tried earlier) is one degree of freedom no matter how it's smoothed
    /// or jittered per bar, so it can never look like more than one block moving together.
    private func computeBands(from samples: [Float]) -> [Float]? {
        guard let fftSetup, samples.count >= fftSize else { return nil }

        let filtered = dcBlock(samples)
        let tail = Array(filtered.suffix(fftSize))

        // Reuse pre-allocated buffers instead of allocating fresh ones on every callback.
        // Zero them out to prepare for reuse.
        vDSP_vclr(&fftWindowed, 1, vDSP_Length(fftSize))
        vDSP_vclr(&fftRealp, 1, vDSP_Length(fftSize / 2))
        vDSP_vclr(&fftImagp, 1, vDSP_Length(fftSize / 2))
        vDSP_vclr(&fftMagnitudes, 1, vDSP_Length(fftSize / 2))

        vDSP_vmul(tail, 1, hannWindow, 1, &fftWindowed, 1, vDSP_Length(fftSize))

        fftWindowed.withUnsafeMutableBufferPointer { windowedPtr in
            guard let baseAddress = windowedPtr.baseAddress else { return }
            baseAddress.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                fftRealp.withUnsafeMutableBufferPointer { realPtr in
                    fftImagp.withUnsafeMutableBufferPointer { imagPtr in
                        var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(fftSize / 2))
                        vDSP_fft_zrip(fftSetup, &split, 1, vDSP_Length(log2(Double(fftSize))), FFTDirection(FFT_FORWARD))
                        // DC and Nyquist are packed into realp[0]/imagp[0] by vDSP's real FFT;
                        // zero them so they don't leak into the first band as bogus energy.
                        split.realp[0] = 0
                        split.imagp[0] = 0
                        vDSP_zvmags(&split, 1, &fftMagnitudes, 1, vDSP_Length(fftSize / 2))
                    }
                }
            }
        }

        // vDSP's real FFT is not power-normalized — its output magnitude scales with fftSize
        // (roughly proportional to fftSize/2 for a full-scale tone), which is a completely
        // different scale than the raw-sample RMS dB calc this app was calibrated against
        // earlier. Without correcting for it, `10*log10(peak)` comes out tens of dB hotter
        // than expected and any real speech saturates every band to 1.0 immediately.
        let fftPowerScale = Float(fftSize / 2) * Float(fftSize / 2)
        let minDb: Float = -50

        // Zero out the bands buffer for reuse
        vDSP_vclr(&bandsMagnitudes, 1, vDSP_Length(numBands))

        for band in 0..<numBands {
            let lo = bandLowBin[band]
            let hi = max(bandHighBin[band], lo + 1)
            var peak: Float = 0
            for bin in lo..<min(hi, fftMagnitudes.count) {
                peak = max(peak, fftMagnitudes[bin])
            }
            let normalizedPeak = peak / fftPowerScale
            let db = (normalizedPeak > 0 ? 10 * log10(normalizedPeak) : minDb) + bandTiltDb[band]
            bandsMagnitudes[band] = max(0, min((db - minDb) / -minDb, 1.0))
        }

        return bandsMagnitudes
    }

    /// One-pole DC-blocking high-pass filter (`y[n] = x[n] - x[n-1] + 0.995*y[n-1]`), applied
    /// only to the copy used for the meter's FFT — not to the audio captured for
    /// transcription. State carries across buffer callbacks so the filter stays continuous
    /// rather than resetting every ~100ms buffer, which would reintroduce a discontinuity at
    /// every buffer boundary.
    private func dcBlock(_ samples: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: samples.count)
        var prevIn = dcPrevIn
        var prevOut = dcPrevOut
        for i in 0..<samples.count {
            let x = samples[i]
            let y = x - prevIn + 0.995 * prevOut
            output[i] = y
            prevIn = x
            prevOut = y
        }
        dcPrevIn = prevIn
        dcPrevOut = prevOut
        return output
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

extension AudioRecorder: AudioRecording {}

enum AudioRecorderError: LocalizedError {
    case engineNotInitialized
    case formatNotAvailable
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .engineNotInitialized:
            return "Audio engine not initialized"
        case .formatNotAvailable:
            return "Microphone isn't delivering audio right now"
        case .recordingFailed(let message):
            return "Recording failed: \(message)"
        }
    }
}
