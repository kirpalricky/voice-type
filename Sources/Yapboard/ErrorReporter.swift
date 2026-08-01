import Foundation
import Sentry

/// Key for deduplicating errors in the tally.
internal struct TallyKey: Hashable {
    let site: String
    let domain: String
    let code: Int
}

/// Aggregated error information for a unique error site/domain/code combination.
internal struct TallyValue {
    var count: Int
    var firstSeen: Date
    var lastSeen: Date
    var lastMessage: String
}

/// Non-fatal error batching singleton.
///
/// Tallies errors in-memory during a session and periodically flushes them as a synthetic
/// Sentry event. Follows DiagnosticLogger's pattern for thread-safe access across MainActor
/// and non-MainActor contexts.
final class ErrorReporter: @unchecked Sendable {
    static let shared = ErrorReporter()

    private let lock = NSLock()
    internal var tally: [TallyKey: TallyValue] = [:]
    private var hasPostedConsentNotificationThisSession = false

    /// Records an error in the tally (unless consent is .disabled).
    /// Extracts domain/code from the NSError and stores the redacted localized description.
    /// If this is the first error tally entry and consent is .unset, posts a notification.
    func report(_ error: Error, site: String) {
        guard CrashReportingConsentManager.shared.state != .disabled else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        let nsError = error as NSError
        let domain = nsError.domain
        let code = nsError.code
        let message = PathRedaction.redact(nsError.localizedDescription)

        let key = TallyKey(site: site, domain: domain, code: code)
        let now = Date()

        let wasEmpty = tally.isEmpty

        if var value = tally[key] {
            value.count += 1
            value.lastSeen = now
            value.lastMessage = message
            tally[key] = value
        } else {
            tally[key] = TallyValue(
                count: 1,
                firstSeen: now,
                lastSeen: now,
                lastMessage: message
            )
        }

        // If this was the first entry added and consent is unset, post a notification
        // to trigger the consent dialog during the session.
        if wasEmpty && CrashReportingConsentManager.shared.state == .unset && !hasPostedConsentNotificationThisSession {
            hasPostedConsentNotificationThisSession = true
            // Dispatch to main thread to post notification (safe to call from any thread).
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("com.yapboard.crashReportingConsentPromptNeeded"), object: nil)
            }
        }
    }

    /// Internal method for tests to safely clear the tally.
    internal func _clearTallyForTesting() {
        lock.lock()
        defer { lock.unlock() }
        tally.removeAll()
    }

    /// Flushes accumulated errors as a synthetic Sentry event and clears the tally.
    /// Only sends if Sentry is configured and consent is not .disabled.
    /// Sends to SentryConfig.errorsHub if available, otherwise uses SentrySDK.
    func flush() {
        lock.lock()
        defer { lock.unlock() }

        guard !tally.isEmpty else {
            return
        }

        // Skip if Sentry is not configured or if consent was explicitly disabled.
        guard SentryConfig.isConfigured, CrashReportingConsentManager.shared.state != .disabled else {
            tally.removeAll()
            return
        }

        // Build synthetic event.
        let event = Sentry.Event(level: .info)
        let eventMessage = "Batched error report (\(tally.count) unique errors this session)"
        event.message = SentryMessage(formatted: eventMessage)

        // Serialize tally into extra dictionary.
        var tallyDict: [String: [String: Any]] = [:]
        for (key, value) in tally {
            let keyString = "\(key.domain):\(key.code)@\(key.site)"
            tallyDict[keyString] = [
                "count": value.count,
                "firstSeen": value.firstSeen.timeIntervalSince1970,
                "lastSeen": value.lastSeen.timeIntervalSince1970,
                "lastMessage": value.lastMessage
            ]
        }
        event.extra = ["tally": tallyDict]

        // Record the event being sent for transparency display in settings,
        // only if consent is actually .enabled (not .unset where it will be held).
        if CrashReportingConsentManager.shared.state == .enabled {
            CrashReportingConsentManager.shared.recordSentEvent(message: eventMessage)
        }

        // Send via errors hub if available, otherwise try SDK (which may not be enabled).
        if let errorsHub = SentryConfig.errorsHub {
            errorsHub.capture(event: event)
        } else if SentrySDK.isEnabled {
            SentrySDK.capture(event: event)
        }

        tally.removeAll()
    }
}
