import Foundation
import Testing
@testable import VoiceType

@Suite
struct SparkleConfigTests {
    /// `Bundle.main` under `swift test` is the test runner's own bundle, not VoiceType.app —
    /// the app's Info.plist is only assembled into a real app bundle by package_app.sh /
    /// scripts/release.sh, so these tests must read the source plist directly off disk.
    private static var infoPlist: [String: Any] {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repoRoot = sourceFile
            .deletingLastPathComponent()  // SparkleConfigTests.swift
            .deletingLastPathComponent()  // VoiceTypeTests
            .deletingLastPathComponent()  // Tests
        let plistURL = repoRoot
            .appendingPathComponent("Sources/VoiceType/Resources/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return [:]
        }
        return plist
    }

    @Test
    func infoPlistContainsSUFeedURL() throws {
        let feedURL = Self.infoPlist["SUFeedURL"] as? String
        #expect(feedURL != nil, "SUFeedURL key must exist in Info.plist")
        #expect(!(feedURL ?? "").isEmpty, "SUFeedURL value must not be empty")
        #expect(URL(string: feedURL ?? "")?.scheme == "https", "SUFeedURL must use https scheme")
    }

    @Test
    func infoPlistContainsSUEnableAutomaticChecks() throws {
        let enableAutoChecks = Self.infoPlist["SUEnableAutomaticChecks"] as? Bool
        #expect(enableAutoChecks == true, "SUEnableAutomaticChecks must be true in Info.plist")
    }

    @Test
    func infoPlistContainsSUPublicEDKey() throws {
        let publicKey = Self.infoPlist["SUPublicEDKey"] as? String
        #expect(publicKey != nil, "SUPublicEDKey key must exist in Info.plist")
        #expect(!(publicKey ?? "").isEmpty, "SUPublicEDKey value must not be empty — an empty key means this build can never receive Sparkle auto-updates")
    }
}
