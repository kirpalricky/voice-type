import Foundation
import Testing
@testable import Yapboard

extension Tag {
    @Tag static var audioEval: Self
}

/// End-to-end robustness eval: synthesizes speech via TTS, degrades it with
/// noise/distortion tricks, and runs it through the REAL Transcriber (Parakeet ASR)
/// to verify vocabulary terms and overall meaning survive degradation.
///
/// Opt-in only (downloads TTS + ASR models on first run, slow): run with
///   YAPBOARD_AUDIO_EVAL=1 swift test --filter AudioRobustnessEvalTests
// .serialized: each case spins up its own real UnifiedAsrManager (CoreML/ANE) — avoid N concurrent model loads.
@Suite(
    .tags(.audioEval),
    .enabled(if: ProcessInfo.processInfo.environment["YAPBOARD_AUDIO_EVAL"] != nil),
    .serialized
)
struct AudioRobustnessEvalTests {
    struct AudioCase: Sendable, CustomStringConvertible {
        let label: String
        let phrase: String
        let mustContain: [String]
        let trick: @Sendable ([Float]) -> [Float]
        let minRecall: Double
        let speed: Float

        var description: String { label }
    }

    static let cases: [AudioCase] = [
        AudioCase(
            label: "clean.baseline",
            phrase: "we run postgres and kubernetes in production and it's been stable",
            mustContain: ["postgres", "kubernetes"],
            trick: { $0 },
            minRecall: 0.8,
            speed: 1.0
        ),
        AudioCase(
            label: "noise.gaussian20db",
            phrase: "we're moving to cloud native infrastructure",
            mustContain: ["cloud native"],
            trick: { TestAudioFixtures.addGaussianNoise($0, snrDB: 20) },
            minRecall: 0.6,
            speed: 1.0
        ),
        AudioCase(
            label: "noise.gaussian10db",
            phrase: "super whisper is really powerful",
            mustContain: ["super whisper"],
            trick: { TestAudioFixtures.addGaussianNoise($0, snrDB: 10) },
            minRecall: 0.4,
            speed: 1.0
        ),
        AudioCase(
            label: "distortion.clip4x",
            phrase: "i've been using voice type all week and it's great",
            mustContain: ["voice type"],
            trick: { TestAudioFixtures.clip($0, gain: 4.0) },
            minRecall: 0.5,
            speed: 1.0
        ),
        AudioCase(
            label: "mic.lowpass",
            phrase: "we use get hub co pilot for most of our code suggestions now",
            mustContain: ["co pilot"],
            trick: { TestAudioFixtures.lowPass($0, alpha: 0.2) },
            minRecall: 0.4,
            speed: 1.0
        ),
        AudioCase(
            label: "padding.silence",
            phrase: "this only works on mac os not on windows",
            mustContain: ["mac os"],
            trick: { TestAudioFixtures.padSilence($0, leadingMs: 500, trailingMs: 500) },
            minRecall: 0.7,
            speed: 1.0
        ),
        AudioCase(
            label: "speed.fast",
            phrase: "cloud native and super whisper and voice type all came up in the same meeting today",
            mustContain: ["cloud native", "voice type"],
            trick: { $0 },
            minRecall: 0.5,
            speed: 1.2
        ),
    ]

    @Test(arguments: cases)
    func robustness(_ testCase: AudioCase) async throws {
        let clean = try await TestAudioFixtures.SharedTTS.shared.samples16k(testCase.phrase, speed: testCase.speed)
        let degraded = testCase.trick(clean)

        let transcriber = Transcriber()
        try await transcriber.initialize()
        let transcript = try await transcriber.transcribe(degraded)
        await transcriber.cleanup()

        let recall = TestAudioFixtures.tokenRecall(reference: testCase.phrase, hypothesis: transcript)
        #expect(
            recall >= testCase.minRecall,
            Comment(rawValue: "\(testCase.label): got '\(transcript)' recall=\(recall)")
        )

        for term in testCase.mustContain {
            #expect(
                TestAudioFixtures.contains(term: term, in: transcript),
                Comment(rawValue: "\(testCase.label): missing '\(term)' in '\(transcript)'")
            )
        }
    }
}
