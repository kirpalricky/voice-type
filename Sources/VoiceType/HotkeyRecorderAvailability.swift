import Foundation

enum HotkeyRecorderAvailability {
    static let resourceBundleName = "KeyboardShortcuts_KeyboardShortcuts.bundle"

    static func isAvailable(bundle: Bundle = .main) -> Bool {
        let path = bundle.bundleURL.appendingPathComponent(resourceBundleName).path
        return FileManager.default.fileExists(atPath: path)
    }
}
