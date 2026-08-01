import Foundation

/// Redacts user home directory paths from strings for privacy.
enum PathRedaction {
    /// Replaces `/Users/<username>/` patterns with `/Users/<redacted>/`.
    static func redact(_ string: String) -> String {
        // Matches /Users/[^/]+/ and replaces with /Users/<redacted>/
        let pattern = "/Users/[^/]+/"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return string
        }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: "/Users/<redacted>/")
    }
}
