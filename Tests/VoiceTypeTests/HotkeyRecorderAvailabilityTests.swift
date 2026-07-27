import Foundation
import Testing
@testable import VoiceType

@Suite
struct HotkeyRecorderAvailabilityTests {
    func createTempDir() -> URL {
        let tempDirPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirPath, withIntermediateDirectories: true)
        return tempDirPath
    }

    @Test
    func isAvailable_ReturnsTrueWhenBundleExists() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a fake bundle directory with the expected name
        let bundlePath = tempDir.appendingPathComponent(HotkeyRecorderAvailability.resourceBundleName, isDirectory: true)
        try FileManager.default.createDirectory(at: bundlePath, withIntermediateDirectories: true)

        // Create a fake bundle object pointing to tempDir
        guard let bundle = Bundle(path: tempDir.path) else {
            Issue.record("Failed to create bundle for testing")
            return
        }

        let result = HotkeyRecorderAvailability.isAvailable(bundle: bundle)
        #expect(result == true)
    }

    @Test
    func isAvailable_ReturnsFalseWhenBundleDoesNotExist() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a fake bundle object pointing to tempDir, but don't create the bundle subdirectory
        guard let bundle = Bundle(path: tempDir.path) else {
            Issue.record("Failed to create bundle for testing")
            return
        }

        let result = HotkeyRecorderAvailability.isAvailable(bundle: bundle)
        #expect(result == false)
    }

    @Test
    func isAvailable_ReturnsFalseWhenBundlePathIsEmpty() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a fake bundle object pointing to a non-existent directory
        let nonExistentPath = tempDir.appendingPathComponent("nonexistent", isDirectory: true).path
        let bundle = Bundle(path: nonExistentPath)

        let result = HotkeyRecorderAvailability.isAvailable(bundle: bundle ?? .main)
        #expect(result == false)
    }
}
