import KeyboardShortcuts
import OSLog

final class HotkeyManager {
    private let logger = OSLog(subsystem: "com.yapboard.app", category: "HotkeyManager")

    init(onKeyDown: @escaping () -> Void, onKeyUp: @escaping () -> Void) {
        DiagnosticLogger.shared.log("HotkeyManager.init registering handlers for .toggleRecording, current shortcut: \(String(describing: KeyboardShortcuts.getShortcut(for: .toggleRecording)))")
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [logger] in
            DiagnosticLogger.shared.log("HotkeyManager: key DOWN fired")
            os_log("Hotkey pressed - starting recording", log: logger, type: .info)
            onKeyDown()
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [logger] in
            DiagnosticLogger.shared.log("HotkeyManager: key UP fired")
            os_log("Hotkey released - stopping recording", log: logger, type: .info)
            onKeyUp()
        }
    }
}
