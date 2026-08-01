import Foundation

enum HotkeyRecorderAvailability {
    static let resourceBundleName = "KeyboardShortcuts_KeyboardShortcuts"
    static let resourceBundleExtension = "bundle"

    static func isAvailable(bundle: Bundle = .main) -> Bool {
        bundle.url(forResource: resourceBundleName, withExtension: resourceBundleExtension) != nil
    }
}
