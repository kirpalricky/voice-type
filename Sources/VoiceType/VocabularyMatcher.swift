import Foundation
import AppKit
import OSLog

/// Provides vocabulary matching capabilities with multiple layers of correction
struct VocabularyMatcher {
    /// Layer 1: Exact/casing match - case-insensitive, phrase-aware find-and-replace
    /// - Parameters:
    ///   - text: The input text to correct
    ///   - glossary: Array of glossary entries to match against
    /// - Returns: Text with exact matches replaced by canonical forms
    static func applyExactMatch(_ text: String, glossary: [GlossaryEntry]) -> String {
        var result = text

        for entry in glossary {
            // Check the canonical form itself
            result = replaceWordBoundary(result, canonicalForm: entry.canonical)

            // Check all variants
            for variant in entry.variants {
                result = replaceWordBoundary(result, variant: variant, canonical: entry.canonical)
            }
        }

        return result
    }

    /// Layer 2: Fuzzy/phonetic match with two critical guards
    /// - Parameters:
    ///   - text: The input text to correct
    ///   - glossary: Array of glossary entries to match against
    /// - Returns: Text with fuzzy matches replaced by canonical forms
    static func applyFuzzyMatch(_ text: String, glossary: [GlossaryEntry]) -> String {
        var result = text
        let words = tokenize(text)

        for (_, word) in words.enumerated() {
            // Guard 1: Dictionary gate - skip if word is already a valid English word
            if isValidEnglishWord(word) {
                continue
            }

            // Try to find a fuzzy match in the glossary
            if let match = findFuzzyMatch(word, in: glossary) {
                let cleanWord = word.lowercased()
                result = replaceCaseInsensitive(result, target: cleanWord, replacement: match.canonical)
            }
        }

        return result
    }

    // MARK: - Helper Methods

    /// Replace a word/phrase with respect to word boundaries (case-insensitive)
    private static func replaceWordBoundary(_ text: String, canonicalForm: String) -> String {
        var result = text
        let canonicalLower = canonicalForm.lowercased()

        // Pattern: word boundary + canonical form (lowercased) + word boundary
        let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: canonicalLower))\\b"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: canonicalForm)
        }

        return result
    }

    /// Replace a variant with the canonical form
    private static func replaceWordBoundary(_ text: String, variant: String, canonical: String) -> String {
        var result = text
        let variantLower = variant.lowercased()

        // Pattern: word boundary + variant (lowercased) + word boundary
        let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: variantLower))\\b"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: canonical)
        }

        return result
    }

    /// Replace case-insensitive occurrences of a word
    private static func replaceCaseInsensitive(_ text: String, target: String, replacement: String) -> String {
        var result = text
        let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: target))\\b"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
        }
        return result
    }

    /// Tokenize text into words and phrases
    private static func tokenize(_ text: String) -> [String] {
        let components = text.split(separator: " ", omittingEmptySubsequences: true)
        return components.map(String.init)
    }

    /// Guard 1: Check if a word is already a valid English word using NSSpellChecker
    /// This prevents false positives by not fuzzy-matching words that are already correct
    private static func isValidEnglishWord(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared

        // Remove punctuation for spell check
        let cleanWord = word.lowercased().trimmingCharacters(in: .punctuationCharacters)

        guard !cleanWord.isEmpty else {
            return false
        }

        // checkSpelling returns the range of a misspelled word
        // If it returns an invalid range (NSNotFound), the word is spelled correctly
        let misspelledRange = checker.checkSpelling(of: cleanWord, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)

        // If misspelledRange.location == NSNotFound, the word is valid/correctly spelled
        return misspelledRange.location == NSNotFound
    }

    /// Guard 2 + Fuzzy matching logic: Find a fuzzy match using Levenshtein distance
    /// Implements length-aware threshold to prevent false positives on short terms
    private static func findFuzzyMatch(_ word: String, in glossary: [GlossaryEntry]) -> GlossaryEntry? {
        let wordLower = word.lowercased()
        var bestMatch: (entry: GlossaryEntry, distance: Int)?
        var bestDistance = Int.max

        for entry in glossary {
            // Check canonical form
            let canonicalDistance = levenshteinDistance(wordLower, entry.canonical.lowercased())
            if shouldAcceptMatch(canonicalDistance, termLength: entry.canonical.count) {
                if canonicalDistance < bestDistance {
                    bestDistance = canonicalDistance
                    bestMatch = (entry, canonicalDistance)
                }
            }

            // Check variants
            for variant in entry.variants {
                let variantDistance = levenshteinDistance(wordLower, variant.lowercased())
                if shouldAcceptMatch(variantDistance, termLength: variant.count) {
                    if variantDistance < bestDistance {
                        bestDistance = variantDistance
                        bestMatch = (entry, variantDistance)
                    }
                }
            }
        }

        return bestMatch?.entry
    }

    /// Determine if a fuzzy match should be accepted based on edit distance and term length
    /// Length-aware threshold:
    /// - Terms ≤5 characters (abbreviations, short terms): only accept exact match (distance 0)
    /// - Terms >5 characters: accept distance ≤2
    private static func shouldAcceptMatch(_ distance: Int, termLength: Int) -> Bool {
        if termLength <= 5 {
            // Short terms (abbreviations): only exact matches
            return distance == 0
        } else {
            // Longer terms: allow up to 2 character differences
            return distance <= 2
        }
    }

    /// Calculate Levenshtein distance (edit distance) between two strings
    /// This measures the minimum number of single-character edits needed to transform one string to another
    private static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1Array = Array(s1)
        let s2Array = Array(s2)
        let m = s1Array.count
        let n = s2Array.count

        if m == 0 { return n }
        if n == 0 { return m }

        // Create DP table
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        // Initialize base cases
        for i in 0...m {
            dp[i][0] = i
        }
        for j in 0...n {
            dp[0][j] = j
        }

        // Fill DP table
        for i in 1...m {
            for j in 1...n {
                if s1Array[i - 1] == s2Array[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = 1 + min(
                        dp[i - 1][j],    // deletion
                        dp[i][j - 1],    // insertion
                        dp[i - 1][j - 1] // substitution
                    )
                }
            }
        }

        return dp[m][n]
    }
}
