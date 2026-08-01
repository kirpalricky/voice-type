import Testing
import Foundation
@testable import Yapboard

@Suite
struct PathRedactionTests {
    // MARK: - Basic Redaction Tests

    @Test
    func basicRedaction_UserPathIsRedacted() {
        let input = "/Users/alice/Documents/file.txt"
        let result = PathRedaction.redact(input)
        #expect(result == "/Users/<redacted>/Documents/file.txt")
    }

    @Test
    func basicRedaction_MultiplePathsInString() {
        let input = "Path1: /Users/alice/Documents/file.txt and /Users/bob/Downloads/file.txt"
        let result = PathRedaction.redact(input)
        #expect(result.contains("alice") == false)
        #expect(result.contains("bob") == false)
        #expect(result.contains("<redacted>") == true)
        // Verify both occurrences are redacted
        let redactedCount = result.components(separatedBy: "<redacted>").count - 1
        #expect(redactedCount == 2)
    }

    @Test
    func basicRedaction_SameUsernameMultipleTimes() {
        let input = "First: /Users/alice/Documents/file.txt and Second: /Users/alice/Downloads/file.txt"
        let result = PathRedaction.redact(input)
        #expect(result.contains("alice") == false)
        let redactedCount = result.components(separatedBy: "<redacted>").count - 1
        #expect(redactedCount == 2)
    }

    // MARK: - No Path Tests

    @Test
    func noPath_StringWithoutPathsIsUnchanged() {
        let input = "This is just some text with no paths"
        let result = PathRedaction.redact(input)
        #expect(result == input)
    }

    @Test
    func noPath_EmptyStringIsUnchanged() {
        let input = ""
        let result = PathRedaction.redact(input)
        #expect(result == "")
    }

    // MARK: - Edge Cases

    @Test
    func edgeCase_UsersDirectoryWithoutUsername() {
        let input = "/Users/"
        let result = PathRedaction.redact(input)
        // This should not match since the pattern requires at least one character after /Users/
        // Verify it doesn't crash and the behavior is reasonable
        #expect(result == input, "/Users/ with no username should not be redacted")
    }

    @Test
    func edgeCase_UsersPrefix() {
        let input = "/Users"
        let result = PathRedaction.redact(input)
        #expect(result == input, "/Users without trailing slash should not be redacted")
    }

    // MARK: - Path in Context Tests

    @Test
    func contextualRedaction_PathInErrorMessage() {
        let input = "Failed to write to /Users/kirpal/Library/Application Support/Yapboard/diagnostics.log: permission denied"
        let result = PathRedaction.redact(input)
        #expect(result.contains("kirpal") == false)
        #expect(result.contains("<redacted>") == true)
        #expect(result.contains("Library/Application Support/Yapboard/diagnostics.log") == true)
        #expect(result.contains("permission denied") == true)
    }

    @Test
    func contextualRedaction_PathWithSpecialCharacters() {
        let input = "Error at /Users/john.doe/Desktop/file-with-dashes_and_underscores.txt"
        let result = PathRedaction.redact(input)
        #expect(result.contains("john.doe") == false)
        #expect(result.contains("<redacted>") == true)
        #expect(result.contains("Desktop/file-with-dashes_and_underscores.txt") == true)
    }

    @Test
    func contextualRedaction_PathWithNumbers() {
        let input = "File: /Users/user123/Documents/file456.txt"
        let result = PathRedaction.redact(input)
        #expect(result.contains("user123") == false)
        #expect(result.contains("<redacted>") == true)
        #expect(result.contains("Documents/file456.txt") == true)
    }

    @Test
    func contextualRedaction_MultiplePathsInLongMessage() {
        let input = "Process 1 failed at /Users/alice/app/config.json, then Process 2 failed at /Users/bob/app/cache.db"
        let result = PathRedaction.redact(input)
        #expect(result.contains("alice") == false)
        #expect(result.contains("bob") == false)
        let redactedCount = result.components(separatedBy: "<redacted>").count - 1
        #expect(redactedCount == 2)
    }

    // MARK: - Preservation Tests

    @Test
    func preservation_NonUserPathsArePreserved() {
        let input = "/Library/Caches/some-file.txt /var/tmp/other-file.txt"
        let result = PathRedaction.redact(input)
        #expect(result == input, "Non-/Users/ paths should not be modified")
    }

    @Test
    func preservation_URLsAreNotCorrupted() {
        let input = "https://example.com/Users/download"
        let result = PathRedaction.redact(input)
        // The URL path doesn't start with / at the beginning of a line and isn't a real /Users/ path
        // Pattern is /Users/[^/]+/ so this shouldn't match
        #expect(result == input)
    }
}
