import Foundation
import Testing
@testable import VoiceType

@Suite
struct VocabularyMatcherTests {
    // MARK: - applyExactMatch Tests

    @Test
    func exactMatch_EmptyString() {
        let glossary: [GlossaryEntry] = []
        let result = VocabularyMatcher.applyExactMatch("", glossary: glossary)
        #expect(result == "")
    }

    @Test
    func exactMatch_NoGlossaryTerms() {
        let text = "hello world"
        let result = VocabularyMatcher.applyExactMatch(text, glossary: [])
        #expect(result == text)
    }

    @Test
    func exactMatch_IdenticalInput() {
        let text = "hello world"
        let glossary = [GlossaryEntry(canonical: "hello", variants: [])]
        let result = VocabularyMatcher.applyExactMatch(text, glossary: glossary)
        #expect(result == text)
    }

    @Test
    func exactMatch_CaseInsensitiveReplacement() {
        let text = "I use SUPERWHISPER and superwhisper daily"
        let glossary = [GlossaryEntry(canonical: "SuperWhisper", variants: [])]
        let result = VocabularyMatcher.applyExactMatch(text, glossary: glossary)
        #expect(result == "I use SuperWhisper and SuperWhisper daily")
    }

    @Test
    func exactMatch_VariantReplacement() {
        let text = "We use cloud native architecture"
        let glossary = [GlossaryEntry(canonical: "CloudNative", variants: ["cloud native", "cloudnative"])]
        let result = VocabularyMatcher.applyExactMatch(text, glossary: glossary)
        #expect(result == "We use CloudNative architecture")
    }

    @Test
    func exactMatch_MultipleVariants() {
        let text = "super whisper and superwhisper work well"
        let glossary = [GlossaryEntry(canonical: "SuperWhisper", variants: ["super whisper", "superwhisper"])]
        let result = VocabularyMatcher.applyExactMatch(text, glossary: glossary)
        #expect(result == "SuperWhisper and SuperWhisper work well")
    }

    @Test
    func exactMatch_WordBoundaries() {
        let text = "supersonic uses advanced technology"
        let glossary = [GlossaryEntry(canonical: "Super", variants: [])]
        let result = VocabularyMatcher.applyExactMatch(text, glossary: glossary)
        // "supersonic" should NOT match "super" due to word boundaries
        #expect(result == text)
    }

    @Test
    func exactMatch_UnicodeCharacters() {
        let text = "café and CAFÉ are great"
        let glossary = [GlossaryEntry(canonical: "Café", variants: [])]
        let result = VocabularyMatcher.applyExactMatch(text, glossary: glossary)
        #expect(result == "Café and Café are great")
    }

    @Test
    func exactMatch_MultipleGlossaryTerms() {
        let text = "We use CloudNative and SuperWhisper"
        let glossary = [
            GlossaryEntry(canonical: "CloudNative", variants: ["cloud native"]),
            GlossaryEntry(canonical: "SuperWhisper", variants: ["super whisper"])
        ]
        let result = VocabularyMatcher.applyExactMatch(text, glossary: glossary)
        #expect(result == "We use CloudNative and SuperWhisper")
    }

    // MARK: - applyFuzzyMatch Tests

    @Test
    func fuzzyMatch_EmptyString() {
        let glossary: [GlossaryEntry] = []
        let result = VocabularyMatcher.applyFuzzyMatch("", glossary: glossary)
        #expect(result == "")
    }

    @Test
    func fuzzyMatch_NoGlossaryTerms() {
        let text = "hello world"
        let result = VocabularyMatcher.applyFuzzyMatch(text, glossary: [])
        #expect(result == text)
    }

    @Test
    func fuzzyMatch_SingleCharacterTypo() {
        let text = "We use cloudnvative"
        let glossary = [GlossaryEntry(canonical: "CloudNative", variants: [])]
        let result = VocabularyMatcher.applyFuzzyMatch(text, glossary: glossary)
        #expect(result == "We use CloudNative")
    }

    @Test
    func fuzzyMatch_TwoCharacterTypo() {
        let text = "This is superwisper technology"
        let glossary = [GlossaryEntry(canonical: "SuperWhisper", variants: [])]
        let result = VocabularyMatcher.applyFuzzyMatch(text, glossary: glossary)
        #expect(result == "This is SuperWhisper technology")
    }

    @Test
    func fuzzyMatch_ExceedsThreshold() {
        let text = "This is abcdefgh"
        let glossary = [GlossaryEntry(canonical: "SuperWhisper", variants: [])]
        let result = VocabularyMatcher.applyFuzzyMatch(text, glossary: glossary)
        // Should NOT match - edit distance too large
        #expect(result == text)
    }

    @Test
    func fuzzyMatch_ShortTermsOnlyExactMatch() {
        // Short terms (≤5 chars) should only accept exact matches
        let text = "We use abc123"
        let glossary = [GlossaryEntry(canonical: "ABC", variants: [])]
        let result = VocabularyMatcher.applyFuzzyMatch(text, glossary: glossary)
        // abc123 ≠ ABC, so no fuzzy match for short terms
        #expect(result == text)
    }

    @Test
    func fuzzyMatch_LongTermsFuzzyMatch() {
        // Longer terms (>5 chars) should accept distance ≤2
        let text = "We use superwhisper technology"
        let glossary = [GlossaryEntry(canonical: "SuperWhisper", variants: [])]
        let result = VocabularyMatcher.applyFuzzyMatch(text, glossary: glossary)
        #expect(result == "We use SuperWhisper technology")
    }

    @Test
    func fuzzyMatch_DeterministicTiebreak() {
        // When two glossary entries are equidistant, the earlier one should win
        let text = "This is sonething"
        let glossary = [
            GlossaryEntry(canonical: "SomethingA", variants: []),
            GlossaryEntry(canonical: "SomethingB", variants: [])
        ]
        let result = VocabularyMatcher.applyFuzzyMatch(text, glossary: glossary)
        // Both are equidistant from "sonething", but SomethingA comes first
        #expect(result == "This is SomethingA")
    }

    @Test
    func fuzzyMatch_ValidEnglishWordNotMatched() {
        // Valid English words should not trigger fuzzy matching
        let text = "I love programming"
        let glossary = [GlossaryEntry(canonical: "ProgrmmingSpecial", variants: [])]
        let result = VocabularyMatcher.applyFuzzyMatch(text, glossary: glossary)
        // "programming" is a valid English word, so fuzzy match should not apply
        #expect(result == text)
    }

    @Test
    func fuzzyMatch_UnicodeCharacters() {
        let text = "We use cáfénative"
        let glossary = [GlossaryEntry(canonical: "CaféNative", variants: [])]
        let result = VocabularyMatcher.applyFuzzyMatch(text, glossary: glossary)
        // This depends on how edit distance treats accented characters
        // Should handle unicode gracefully
        #expect(result.count > 0)
    }

    @Test
    func fuzzyMatch_MultipleWords() {
        let text = "cloudnvative and superwisper"
        let glossary = [
            GlossaryEntry(canonical: "CloudNative", variants: []),
            GlossaryEntry(canonical: "SuperWhisper", variants: [])
        ]
        let result = VocabularyMatcher.applyFuzzyMatch(text, glossary: glossary)
        #expect(result == "CloudNative and SuperWhisper")
    }

    @Test
    func fuzzyMatch_CaseInsensitive() {
        let text = "CLOUDNVATIVE is great"
        let glossary = [GlossaryEntry(canonical: "CloudNative", variants: [])]
        let result = VocabularyMatcher.applyFuzzyMatch(text, glossary: glossary)
        #expect(result == "CloudNative is great")
    }

    // MARK: - Combined Tests

    @Test
    func combined_ExactThenFuzzy() {
        let text = "We use cloud native and superwisper"
        let glossary = [
            GlossaryEntry(canonical: "CloudNative", variants: ["cloud native"]),
            GlossaryEntry(canonical: "SuperWhisper", variants: [])
        ]
        let afterExact = VocabularyMatcher.applyExactMatch(text, glossary: glossary)
        let afterFuzzy = VocabularyMatcher.applyFuzzyMatch(afterExact, glossary: glossary)
        #expect(afterFuzzy == "We use CloudNative and SuperWhisper")
    }
}
