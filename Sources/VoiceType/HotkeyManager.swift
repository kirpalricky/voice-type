import KeyboardShortcuts
import OSLog

final class HotkeyManager {
    private let logger = OSLog(subsystem: "com.voicetype.app", category: "HotkeyManager")

    init(onKeyDown: @escaping () -> Void, onKeyUp: @escaping () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [logger] in
            os_log("Hotkey pressed - starting recording", log: logger, type: .info)
            onKeyDown()
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [logger] in
            os_log("Hotkey released - stopping recording", log: logger, type: .info)
            onKeyUp()
        }
    }
}
