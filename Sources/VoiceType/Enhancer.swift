import Foundation

#if os(macOS)
import FoundationModels
#endif

/// Enhancer provides LLM-based transcript polishing using Apple's on-device Foundation Models
struct Enhancer {
    /// Check if Foundation Models are available on this device
    static var isAvailable: Bool {
        if #available(macOS 26, *) {
            let model = SystemLanguageModel.default
            return model.isAvailable
        } else {
            return false
        }
    }

    /// Polish a raw transcript using on-device Foundation Models
    /// - Parameters:
    ///   - rawTranscript: The raw transcript from speech recognition
    ///   - glossary: Optional list of preferred terms to use in the output
    /// - Returns: A polished transcript with corrected punctuation, casing, and filler words removed.
    ///            If the model is unavailable, returns the raw transcript unchanged.
    static func polish(_ rawTranscript: String, glossary: [String]) async throws -> String {
        // Graceful fallback if Foundation Models are not available
        if !isAvailable {
            return rawTranscript
        }

        if #available(macOS 26, *) {
            // Build glossary instructions
            let glossaryInstructions: String
            if glossary.isEmpty {
                glossaryInstructions = ""
            } else {
                glossaryInstructions = "\n\nPreferred terminology (use these over similar-sounding alternatives if the transcript contains near-misses):\n" + glossary.joined(separator: ", ")
            }

            // Create the prompt with system instructions and few-shot examples
            let systemPrompt = """
            You are a transcript polisher. Your job is to:
            1. Fix punctuation and capitalization
            2. Remove filler words like "um", "uh", "like" (when used as a filler)
            3. Preserve the original meaning and tone
            4. Correct common speech-to-text mishearings\(glossaryInstructions)

            Here are two examples of corrections:

            Example 1 (mishearing correction):
            Input: "we're moving to cloud native infrastructure"
            Output: "We're moving to CloudNative infrastructure."

            Example 2 (casing correction):
            Input: "super whisper is really powerful"
            Output: "SuperWhisper is really powerful."

            Now polish the following transcript, applying the same corrections:
            """

            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: systemPrompt
            )

            let response = try await session.respond(to: rawTranscript)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // Fallback for systems without Foundation Models
            return rawTranscript
        }
    }
}
