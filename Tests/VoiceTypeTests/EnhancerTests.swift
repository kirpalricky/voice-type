import Foundation
import Testing
@testable import VoiceType

@Suite
struct EnhancerTests {
    // MARK: - isLikelyHallucination Tests

    @Test
    func isLikelyHallucination_EmptyRaw_ReturnsFalse() {
        #expect(Enhancer.isLikelyHallucination(raw: "", polished: "anything at all here") == false)
    }

    @Test
    func isLikelyHallucination_NormalPolishing_ReturnsFalse() {
        let raw = "we're moving to cloud native infrastructure"
        let polished = "We're moving to CloudNative infrastructure."
        #expect(Enhancer.isLikelyHallucination(raw: raw, polished: polished) == false)
    }

    @Test
    func isLikelyHallucination_MinorExpansion_ReturnsFalse() {
        let raw = "ok"
        let polished = "Okay."
        #expect(Enhancer.isLikelyHallucination(raw: raw, polished: polished) == false)
    }

    @Test
    func isLikelyHallucination_NumericCountoffExpandedIntoList_ReturnsTrue() {
        // Regression test: raw was a numeric count-off; the model hallucinated
        // a 10-item "CloudNative infrastructure" article instead of polishing it.
        let raw = "1, 2, 3, 4, 5, 6, 7, 8, 9, 10. Okay, great. Awesome. This is working great. Now I will stop recording and see what happens"
        let polished = """
        Okay, let's polish the transcript.

        1. We're moving to CloudNative infrastructure.
        2. CloudNative is a powerful platform for developing and managing applications.
        3. It provides a wide range of features, including containerization, orchestration, and monitoring.
        4. CloudNative is also highly scalable, allowing you to easily scale your applications up or down based on demand.
        """
        #expect(Enhancer.isLikelyHallucination(raw: raw, polished: polished) == true)
    }

    @Test
    func isLikelyHallucination_ShortInputWildlyExpanded_ReturnsTrue() {
        let raw = "hello"
        let polished = String(repeating: "This is a completely fabricated sentence. ", count: 10)
        #expect(Enhancer.isLikelyHallucination(raw: raw, polished: polished) == true)
    }

    @Test
    func isLikelyHallucination_LongerButProportionalPolish_ReturnsFalse() {
        let raw = "um so like i think we should uh go with the new plan"
        let polished = "So, I think we should go with the new plan, incorporating the feedback we received."
        #expect(Enhancer.isLikelyHallucination(raw: raw, polished: polished) == false)
    }

    // MARK: - isLikelyOverCompressed Tests

    @Test
    func isLikelyOverCompressed_ShortInput_ReturnsFalse() {
        #expect(Enhancer.isLikelyOverCompressed(raw: "ok", polished: "Okay.") == false)
    }

    @Test
    func isLikelyOverCompressed_NormalFillerRemoval_ReturnsFalse() {
        let raw = "um so like i think we should uh go with the new plan"
        let polished = "I think we should go with the new plan."
        #expect(Enhancer.isLikelyOverCompressed(raw: raw, polished: polished) == false)
    }

    @Test
    func isLikelyOverCompressed_SummarizedIntoOneSentence_ReturnsTrue() {
        // Regression test: the model condensed a two-clause rambling instruction
        // down to a single terse sentence, dropping most of the actual content.
        let raw = "Let's see if this recording is getting transcribed properly or not. Use words like cloud native and super whisper also to see if those words are picked up from the language correctly"
        let polished = "CloudNative and SuperWhisper are picked up correctly."
        #expect(Enhancer.isLikelyOverCompressed(raw: raw, polished: polished) == true)
    }

    // MARK: - stripTranscriptTags Tests

    @Test
    func stripTranscriptTags_WrappedOutput_RemovesBothTags() {
        let text = "<transcript>Hello there.</transcript>"
        #expect(Enhancer.stripTranscriptTags(text) == "Hello there.")
    }

    @Test
    func stripTranscriptTags_OnlyOpeningTagEchoed_RemovesIt() {
        let text = "<transcript>Hello there."
        #expect(Enhancer.stripTranscriptTags(text) == "Hello there.")
    }

    @Test
    func stripTranscriptTags_NoTagsPresent_ReturnsUnchanged() {
        let text = "Hello there."
        #expect(Enhancer.stripTranscriptTags(text) == "Hello there.")
    }
}
