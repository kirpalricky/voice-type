import Foundation
import Testing
@testable import Yapboard

/// Table-driven eval cases for Enhancer's polishing safety net (`isUnfaithfulPolish`).
/// These are not unit tests of a single code path — they're a growing regression
/// corpus of realistic (raw, polished) pairs across transcript lengths and
/// vocabulary/mishearing corrections, used to catch both false negatives (bad
/// polishes that slip through) and false positives (good polishes that get
/// wrongly discarded).
@Suite
struct PolishingEvalTests {
    struct EvalCase: Sendable, CustomStringConvertible {
        let label: String
        let raw: String
        let polished: String
        let expectFallback: Bool

        var description: String { label }
    }

    // MARK: - Length evals

    static let lengthCases: [EvalCase] = [
        // --- Very short (single word / a few words) ---
        EvalCase(
            label: "short.faithful.ack",
            raw: "ok",
            polished: "Okay.",
            expectFallback: false
        ),
        EvalCase(
            label: "short.faithful.singleWord",
            raw: "yeah",
            polished: "Yeah.",
            expectFallback: false
        ),
        EvalCase(
            label: "short.hallucinated.expandedFromOneWord",
            raw: "hello",
            polished: "Hello! I'm doing great today, thank you so much for asking. How can I help you with your project this afternoon?",
            expectFallback: true
        ),

        // --- Short sentence (~1 sentence) ---
        EvalCase(
            label: "short.faithful.fillerRemoved",
            raw: "um so like i think we should uh go with the new plan",
            polished: "I think we should go with the new plan.",
            expectFallback: false
        ),
        EvalCase(
            label: "short.faithful.mishearingFix",
            raw: "we're moving to cloud native infrastructure",
            polished: "We're moving to CloudNative infrastructure.",
            expectFallback: false
        ),
        EvalCase(
            label: "short.overCompressed.droppedClause",
            raw: "I went to the store, bought some milk, and then realized I forgot my wallet at home",
            polished: "I went to the store.",
            expectFallback: true
        ),

        // --- Medium (multi-sentence, ~150-300 chars) ---
        EvalCase(
            label: "medium.faithful.multiSentenceCleanup",
            raw: "so basically um what we need to do is uh first fix the login bug and then like deploy it to staging so qa can test it before friday",
            polished: "Basically, what we need to do is first fix the login bug, and then deploy it to staging so QA can test it before Friday.",
            expectFallback: false
        ),
        EvalCase(
            label: "medium.faithful.numberedNotesPreserved",
            raw: "three things to cover today. one, the budget review. two, the hiring plan. three, the roadmap for next quarter",
            polished: "Three things to cover today: one, the budget review; two, the hiring plan; three, the roadmap for next quarter.",
            expectFallback: false
        ),
        EvalCase(
            label: "medium.overCompressed.summarizedToOneLine",
            // Regression: raw seen in production; model condensed a two-clause
            // rambling instruction down to a single terse sentence.
            raw: "Let's see if this recording is getting transcribed properly or not. Use words like cloud native and super whisper also to see if those words are picked up from the language correctly",
            polished: "CloudNative and SuperWhisper are picked up correctly.",
            expectFallback: true
        ),
        EvalCase(
            label: "medium.hallucinated.numericCountoffToArticle",
            // Regression: raw seen in production; a numeric count-off got expanded
            // into a fabricated 10-item article about "CloudNative infrastructure".
            raw: "1, 2, 3, 4, 5, 6, 7, 8, 9, 10. Okay, great. Awesome. This is working great. Now I will stop recording and see what happens",
            polished: """
            Okay, let's polish the transcript.

            1. We're moving to CloudNative infrastructure.
            2. CloudNative is a powerful platform for developing and managing applications.
            3. It provides a wide range of features, including containerization, orchestration, and monitoring.
            4. CloudNative is also highly scalable, allowing you to easily scale your applications up or down based on demand.
            """,
            expectFallback: true
        ),

        // --- Long (multi-paragraph, 500+ chars) ---
        EvalCase(
            label: "long.faithful.fillerHeavyButProportional",
            raw: """
            okay so um the way i see it is like we have three options here. uh first we could just patch the existing system and uh ship a quick fix. second we could like do a partial rewrite of the module that's causing issues. and third um we could just rewrite the whole thing from scratch which uh honestly i don't think we have time for given the deadline next month
            """,
            polished: """
            Okay, the way I see it is we have three options here. First, we could just patch the existing system and ship a quick fix. Second, we could do a partial rewrite of the module that's causing issues. And third, we could just rewrite the whole thing from scratch, which, honestly, I don't think we have time for given the deadline next month.
            """,
            expectFallback: false
        ),
        EvalCase(
            label: "long.overCompressed.paragraphToSentence",
            raw: """
            okay so um the way i see it is like we have three options here. uh first we could just patch the existing system and uh ship a quick fix. second we could like do a partial rewrite of the module that's causing issues. and third um we could just rewrite the whole thing from scratch which uh honestly i don't think we have time for given the deadline next month
            """,
            polished: "We have three options: patch, rewrite part, or rewrite everything.",
            expectFallback: true
        ),
    ]

    @Test(arguments: lengthCases)
    func lengthEval(_ testCase: EvalCase) {
        #expect(
            Enhancer.isUnfaithfulPolish(raw: testCase.raw, polished: testCase.polished) == testCase.expectFallback,
            Comment(rawValue: testCase.label)
        )
    }

    // MARK: - Vocabulary / mishearing-correction evals

    static let vocabularyCases: [EvalCase] = [
        EvalCase(
            label: "vocab.cloudNative",
            raw: "we're moving to cloud native infrastructure",
            polished: "We're moving to CloudNative infrastructure.",
            expectFallback: false
        ),
        EvalCase(
            label: "vocab.superWhisper",
            raw: "super whisper is really powerful",
            polished: "SuperWhisper is really powerful.",
            expectFallback: false
        ),
        EvalCase(
            label: "vocab.yapboard",
            raw: "i've been using yap board all week and it's great",
            polished: "I've been using Yapboard all week, and it's great.",
            expectFallback: false
        ),
        EvalCase(
            label: "vocab.macOS",
            raw: "this only works on mac os not on windows",
            polished: "This only works on macOS, not on Windows.",
            expectFallback: false
        ),
        EvalCase(
            label: "vocab.githubCopilot",
            raw: "we use get hub co pilot for most of our code suggestions now",
            polished: "We use GitHub Copilot for most of our code suggestions now.",
            expectFallback: false
        ),
        EvalCase(
            label: "vocab.postgresKubernetes",
            raw: "we run postgres and kubernetes in production and it's been stable",
            polished: "We run PostgreSQL and Kubernetes in production, and it's been stable.",
            expectFallback: false
        ),
        EvalCase(
            label: "vocab.multipleTermsOneSentence",
            raw: "cloud native and super whisper and yap board all came up in the same meeting today",
            polished: "CloudNative, SuperWhisper, and Yapboard all came up in the same meeting today.",
            expectFallback: false
        ),
        EvalCase(
            label: "vocab.hallucinatedElaborationOnTerm",
            // A vocabulary correction is not license to add unrequested explanation.
            raw: "we're moving to cloud native infrastructure",
            polished: "We're moving to CloudNative infrastructure, a modern approach to building and running scalable applications in dynamic environments such as public, private, and hybrid clouds.",
            expectFallback: true
        ),
    ]

    @Test(arguments: vocabularyCases)
    func vocabularyEval(_ testCase: EvalCase) {
        #expect(
            Enhancer.isUnfaithfulPolish(raw: testCase.raw, polished: testCase.polished) == testCase.expectFallback,
            Comment(rawValue: testCase.label)
        )
    }
}
