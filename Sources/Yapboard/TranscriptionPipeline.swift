import Foundation

/// Orchestrates the complete transcription pipeline: transcribe → vocabulary matching → polishing.
/// Extracted from TranscriptionCoordinator to be reusable for both live recordings and reprocessing.
enum TranscriptionPipeline {
    struct Result {
        let rawTranscript: String
        let polishedTranscript: String
    }

    /// Runs the complete transcription pipeline on audio samples.
    /// - Parameters:
    ///   - audioSamples: Raw audio samples at any sample rate (will be passed to transcriber as-is)
    ///   - transcriber: Speech-to-text service
    ///   - polisher: Transcript enhancement service
    ///   - glossary: Glossary entries for vocabulary matching (hoisted from GlossaryStore on main actor)
    /// - Returns: Result containing both raw and polished transcripts
    /// - Throws: Any error from transcriber or polisher
    static func run(
        audioSamples: [Float],
        transcriber: Transcribing,
        polisher: Polishing,
        glossary: [GlossaryEntry]
    ) async throws -> Result {
        // Transcribe audio
        let rawTranscript = try await transcriber.transcribe(audioSamples)

        // Layer 1: Apply exact match (case-insensitive, phrase-aware)
        let afterExactMatch = VocabularyMatcher.applyExactMatch(rawTranscript, glossary: glossary)

        // Layer 2: Apply fuzzy match (with dictionary gate and length-aware threshold)
        let afterFuzzyMatch = VocabularyMatcher.applyFuzzyMatch(afterExactMatch, glossary: glossary)

        // Layer 3: Polish transcript using on-device Foundation Models with glossary hints
        let glossaryStrings = glossary.map { entry in
            if entry.variants.isEmpty {
                return entry.canonical
            } else {
                return "\(entry.canonical) (also heard as: \(entry.variants.joined(separator: ", ")))"
            }
        }
        let polishedTranscript = try await polisher.polish(afterFuzzyMatch, glossary: glossaryStrings)

        return Result(rawTranscript: rawTranscript, polishedTranscript: polishedTranscript)
    }
}
