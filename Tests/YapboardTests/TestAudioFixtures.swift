import Foundation
import FluidAudio

/// Test-only helpers for synthesizing "fake recordings" via TTS and degrading them
/// with noise/distortion tricks, used by audio robustness eval tests.
enum TestAudioFixtures {

    /// Lazily initializes FluidAudio's KokoroAne TTS once per test run and
    /// synthesizes speech resampled to 16kHz mono for the ASR pipeline.
    actor SharedTTS {
        static let shared = SharedTTS()

        // A cached in-flight/completed init Task, not an Optional<KokoroAneManager>,
        // so concurrent `@Test(arguments:)` invocations that both see "not yet
        // initialized" before the first `await` still converge on a single
        // KokoroAneManager instead of each constructing and initializing their own
        // (actor isolation alone doesn't prevent this: the lazy-init `await` inside
        // an actor method is a reentrancy point).
        private var initTask: Task<KokoroAneManager, Error>?

        private init() {}

        private func manager() async throws -> KokoroAneManager {
            if let initTask { return try await initTask.value }
            let task = Task<KokoroAneManager, Error> {
                let m = KokoroAneManager()
                try await m.initialize()
                return m
            }
            initTask = task
            return try await task.value
        }

        /// Synthesize `text` and return 16kHz mono Float samples in -1.0...1.0 range.
        func samples16k(_ text: String, speed: Float = 1.0) async throws -> [Float] {
            let manager = try await manager()

            // Synthesize at default sample rate (24000 Hz)
            let result = try await manager.synthesizeDetailed(text: text, speed: speed)

            // Resample to 16kHz
            let converter = AudioConverter(sampleRate: 16000)
            let resampled = try converter.resample(result.samples, from: Double(result.sampleRate))

            return resampled
        }
    }

    // MARK: - Noise / distortion tricks (pure functions, [Float] -> [Float])

    /// Adds Gaussian white noise (Box-Muller transform) scaled to hit the target SNR
    /// (computed from the input signal's RMS).
    static func addGaussianNoise(_ samples: [Float], snrDB: Double) -> [Float] {
        guard !samples.isEmpty else { return samples }

        // Compute signal RMS
        let signalRMS = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))

        // Avoid division by zero
        guard signalRMS > 0 else { return samples }

        // Compute noise RMS from target SNR: noiseRMS = signalRMS / 10^(snrDB/20)
        let noiseRMS = signalRMS / pow(10.0, snrDB / 20.0)

        // Generate Gaussian noise using Box-Muller transform
        var result = samples
        var i = 0
        while i < samples.count {
            // Generate two uniform random numbers in [0.0001, 1.0)
            let u1 = Double.random(in: 0.0001..<1.0)
            let u2 = Double.random(in: 0.0001..<1.0)

            // Box-Muller transform
            let r = sqrt(-2.0 * log(u1))
            let theta = 2.0 * .pi * u2
            let z0 = r * cos(theta)
            let z1 = r * sin(theta)

            // Apply noise scaled by noiseRMS
            if i < samples.count {
                result[i] = Float(Double(samples[i]) + z0 * noiseRMS)
                i += 1
            }
            if i < samples.count {
                result[i] = Float(Double(samples[i]) + z1 * noiseRMS)
                i += 1
            }
        }

        return result
    }

    /// Adds uniform random noise in [-amplitude, amplitude].
    static func addUniformNoise(_ samples: [Float], amplitude: Float = 0.1) -> [Float] {
        return samples.map { sample in
            let noise = Float.random(in: -amplitude...amplitude)
            return sample + noise
        }
    }

    /// Applies gain then clamps to [-1, 1] to simulate clipping/overdrive distortion.
    static func clip(_ samples: [Float], gain: Float) -> [Float] {
        return samples.map { sample in
            let clipped = sample * gain
            return max(-1.0, min(1.0, clipped))
        }
    }

    /// Pads with digital silence (0.0) at the start and/or end, given a 16kHz sample rate.
    static func padSilence(_ samples: [Float], leadingMs: Int, trailingMs: Int, sampleRate: Int = 16000) -> [Float] {
        let leadingSamples = (leadingMs * sampleRate) / 1000
        let trailingSamples = (trailingMs * sampleRate) / 1000

        var result = [Float](repeating: 0.0, count: leadingSamples)
        result.append(contentsOf: samples)
        result.append(contentsOf: [Float](repeating: 0.0, count: trailingSamples))

        return result
    }

    /// One-pole IIR low-pass filter: y[n] = y[n-1] + alpha * (x[n] - y[n-1]).
    /// Simulates a muffled/bad microphone. Smaller alpha = more muffled.
    static func lowPass(_ samples: [Float], alpha: Float = 0.25) -> [Float] {
        guard !samples.isEmpty else { return samples }

        var result = [Float]()
        result.reserveCapacity(samples.count)

        var y: Float = samples[0]
        result.append(y)

        for i in 1..<samples.count {
            y = y + alpha * (samples[i] - y)
            result.append(y)
        }

        return result
    }

    // MARK: - Text scoring helpers

    /// Lowercases, strips punctuation, and splits into whitespace-separated tokens.
    static func normalize(_ text: String) -> [String] {
        let lowercased = text.lowercased()

        // Remove characters that are not letters, digits, or whitespace
        let filtered = lowercased.filter { char in
            char.isLetter || char.isNumber || char.isWhitespace
        }

        // Split on whitespace and drop empty tokens
        return filtered.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    /// Fraction (0.0...1.0) of `reference`'s tokens that also appear in `hypothesis`'s tokens.
    /// Returns 1.0 if reference has no tokens.
    static func tokenRecall(reference: String, hypothesis: String) -> Double {
        let refTokens = normalize(reference)
        let hypTokens = normalize(hypothesis)

        guard !refTokens.isEmpty else { return 1.0 }

        let hypSet = Set(hypTokens)
        let matchCount = refTokens.filter { hypSet.contains($0) }.count

        return Double(matchCount) / Double(refTokens.count)
    }

    /// Whitespace/case/punctuation-insensitive substring check: does `term` appear in `transcript`?
    /// Checks both the spaced form ("cloud native") and the word-fused form ("cloudnative"),
    /// since raw ASR output for multi-word brand terms isn't reliably spaced the same way twice
    /// — that's exactly the kind of drift VocabularyMatcher exists to fix downstream, but this
    /// suite is testing the raw ASR layer before that correction runs.
    static func contains(term: String, in transcript: String) -> Bool {
        let termTokens = normalize(term)
        let transcriptTokens = normalize(transcript)

        guard !termTokens.isEmpty else { return true }

        let termJoined = termTokens.joined(separator: " ")
        let transcriptJoined = transcriptTokens.joined(separator: " ")
        if transcriptJoined.contains(termJoined) { return true }

        let termCompact = termTokens.joined()
        let transcriptCompact = transcriptTokens.joined()
        return transcriptCompact.contains(termCompact)
    }
}
