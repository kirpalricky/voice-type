import Foundation

/// Persistent, user-toggleable diagnostic logging to a plain text file, for tracing app
/// lifecycle/pipeline events when debugging an issue that only shows up in a packaged build
/// (where Xcode's console isn't available). Off by default; enabled via the About tab.
///
/// Deliberately thread-safe and not actor-isolated so it can be called directly from actors
/// (AudioRecorder, Transcriber) as well as MainActor code (VoiceTypeApp, TranscriptionCoordinator)
/// without forcing a hop just to log.
final class DiagnosticLogger: @unchecked Sendable {
    static let shared = DiagnosticLogger()

    private let defaultsKey = "diagnosticLoggingEnabled"
    private let fileManager = FileManager.default
    private let lock = NSLock()

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    var logFileURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("VoiceType", isDirectory: true)
        return dir.appendingPathComponent("diagnostics.log")
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Writes a line to the diagnostics log if logging is currently enabled. Best-effort:
    /// failures are silently ignored — diagnostics must never crash or disrupt the app.
    func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "[\(Self.timestampFormatter.string(from: Date()))] \(message())\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        do {
            let dir = logFileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: logFileURL.path) {
                let handle = try FileHandle(forWritingTo: logFileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: logFileURL)
            }
        } catch {
            // Best-effort only.
        }
    }

    /// Deletes the log file, if any. Safe to call even when logging is disabled.
    func clearLog() {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: logFileURL)
    }
}
