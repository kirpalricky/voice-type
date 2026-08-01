import Foundation
import AppKit
import OSLog

/// Provides vocabulary matching capabilities with multiple layers of correction
struct VocabularyMatcher {
    // MARK: - Static Cache for Compiled Regexes
    /// Cache of compiled NSRegularExpression objects keyed by escaped pattern
    /// This prevents recompilation of the same regex patterns on every call
    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexCacheLock = NSLock()

    /// Get or create a cached regex for the given pattern
    private static func cachedRegex(for pattern: String) -> NSRegularExpression? {
        regexCacheLock.lock()
        defer { regexCacheLock.unlock() }

        if let cached = regexCache[pattern] {
            return cached
        }

        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            regexCache[pattern] = regex
            return regex
        }
        return nil
    }

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
        if let regex = cachedRegex(for: pattern) {
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
        if let regex = cachedRegex(for: pattern) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: canonical)
        }

        return result
    }

    /// Replace case-insensitive occurrences of a word
    private static func replaceCaseInsensitive(_ text: String, target: String, replacement: String) -> String {
        var result = text
        let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: target))\\b"
        if let regex = cachedRegex(for: pattern) {
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
    /// When multiple candidates tie on distance, prefers the one that appears first in the glossary (deterministic)
    private static func findFuzzyMatch(_ word: String, in glossary: [GlossaryEntry]) -> GlossaryEntry? {
        let wordLower = word.lowercased()
        var bestMatch: (entry: GlossaryEntry, distance: Int, glossaryIndex: Int)?
        var bestDistance = Int.max

        for (glossaryIndex, entry) in glossary.enumerated() {
            // Check canonical form
            let canonicalDistance = levenshteinDistance(wordLower, entry.canonical.lowercased())
            if shouldAcceptMatch(canonicalDistance, termLength: entry.canonical.count) {
                // Update if better distance, OR same distance but earlier in glossary
                if canonicalDistance < bestDistance ||
                   (canonicalDistance == bestDistance && (bestMatch == nil || glossaryIndex < bestMatch!.glossaryIndex)) {
                    bestDistance = canonicalDistance
                    bestMatch = (entry, canonicalDistance, glossaryIndex)
                }
            }

            // Check variants
            for variant in entry.variants {
                let variantDistance = levenshteinDistance(wordLower, variant.lowercased())
                if shouldAcceptMatch(variantDistance, termLength: variant.count) {
                    // Update if better distance, OR same distance but earlier in glossary
                    if variantDistance < bestDistance ||
                       (variantDistance == bestDistance && (bestMatch == nil || glossaryIndex < bestMatch!.glossaryIndex)) {
                        bestDistance = variantDistance
                        bestMatch = (entry, variantDistance, glossaryIndex)
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
    /// Uses O(min(m,n)) space via rolling-row optimization instead of O(m*n) full matrix
    /// This measures the minimum number of single-character edits needed to transform one string to another
    private static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1Array = Array(s1)
        let s2Array = Array(s2)
        let m = s1Array.count
        let n = s2Array.count

        if m == 0 { return n }
        if n == 0 { return m }

        // Early exit: if length difference exceeds typical threshold (2), skip expensive computation
        // This is a heuristic for the glossary use-case where we only accept distance <= 2 for longer terms
        if abs(m - n) > 2 {
            return abs(m - n)
        }

        // Use rolling two-row optimization: only keep current and previous row
        // Swap between them to avoid allocating a full (m+1) x (n+1) matrix
        var previousRow = Array(0...n)
        var currentRow = Array(repeating: 0, count: n + 1)

        for i in 1...m {
            currentRow[0] = i

            for j in 1...n {
                if s1Array[i - 1] == s2Array[j - 1] {
                    currentRow[j] = previousRow[j - 1]
                } else {
                    currentRow[j] = 1 + min(
                        previousRow[j],      // deletion
                        currentRow[j - 1],   // insertion
                        previousRow[j - 1]   // substitution
                    )
                }
            }

            // Swap rows for next iteration
            swap(&previousRow, &currentRow)
        }

        return previousRow[n]
    }
}
