import Foundation
import Sentry

enum CrashReportingConsentState: String {
    case unset, enabled, disabled
}

/// Manages three-state crash reporting consent and holds events captured before consent is given.
///
/// Thread-safe singleton following the DiagnosticLogger pattern: callable from both MainActor and
/// non-MainActor contexts without forcing a hop. Uses NSLock for synchronization.
final class CrashReportingConsentManager: @unchecked Sendable {
    static let shared = CrashReportingConsentManager()

    private let defaultsKey = "crashReportingConsentState"
    private let lastSentEventSummaryKey = "crashReportingLastSentEventSummary"
    private let lock = NSLock()
    private var heldEvents: [Sentry.Event] = []

    var state: CrashReportingConsentState {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey) else {
                return .unset
            }
            return CrashReportingConsentState(rawValue: rawValue) ?? .unset
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var hasPendingConsentPrompt: Bool {
        lock.lock()
        defer { lock.unlock() }
        // Read state directly to avoid nested lock acquisition
        guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
              let stateValue = CrashReportingConsentState(rawValue: rawValue) else {
            return !heldEvents.isEmpty
        }
        return stateValue == .unset && !heldEvents.isEmpty
    }

    /// Returns the last sent event summary (message + timestamp) for display in settings, or nil if none.
    var lastSentEventSummary: String? {
        lock.lock()
        defer { lock.unlock() }
        return UserDefaults.standard.string(forKey: lastSentEventSummaryKey)
    }

    /// Holds an event in memory while consent is unset.
    /// If consent state is not .unset, the event is silently dropped (beforeSend handles sending).
    func holdEvent(_ event: Sentry.Event) {
        lock.lock()
        defer { lock.unlock() }
        // Read state directly to avoid nested lock acquisition
        let rawValue = UserDefaults.standard.string(forKey: defaultsKey)
        let stateValue = rawValue.flatMap { CrashReportingConsentState(rawValue: $0) } ?? .unset
        if stateValue == .unset {
            heldEvents.append(event)
        }
    }

    /// Returns and clears all held events. Called when consent becomes .enabled or is permanently dismissed.
    func consumeHeldEvents() -> [Sentry.Event] {
        lock.lock()
        defer { lock.unlock() }
        let events = heldEvents
        heldEvents.removeAll()
        return events
    }

    /// Records the summary of a sent event for later display in settings (e.g., "Last report: ...").
    /// Called after an event is successfully sent by Sentry.
    func recordSentEvent(message: String) {
        lock.lock()
        defer { lock.unlock() }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let timestamp = formatter.string(from: Date())
        let summary = "\(message) at \(timestamp)"
        UserDefaults.standard.set(summary, forKey: lastSentEventSummaryKey)
    }

    /// Checks whether the consent dialog should be shown on app launch.
    /// Returns true if consent is unset AND either a crash was detected or there are held events.
    var shouldShowConsentDialog: Bool {
        lock.lock()
        defer { lock.unlock() }
        // Read state directly to avoid nested lock acquisition
        let rawValue = UserDefaults.standard.string(forKey: defaultsKey)
        let stateValue = rawValue.flatMap { CrashReportingConsentState(rawValue: $0) } ?? .unset
        // Only show if consent hasn't been given yet
        guard stateValue == .unset else { return false }
        // Show if Sentry detected a crash on the previous run, or if there are held events
        return SentrySDK.crashedLastRun || !heldEvents.isEmpty
    }

    /// Handles the user clicking "Enable Reporting": sets consent to .enabled and replays held events.
    func enableReporting() {
        lock.lock()
        // Set state directly to avoid nested lock acquisition
        UserDefaults.standard.set(CrashReportingConsentState.enabled.rawValue, forKey: defaultsKey)
        let events = heldEvents
        heldEvents.removeAll()
        lock.unlock()

        // Replay held events now that consent is given (call outside lock to avoid deadlock)
        for event in events {
            if let message = event.message?.formatted {
                recordSentEvent(message: message)
            }
            SentrySDK.capture(event: event)
        }
    }

    /// Handles the user clicking "No Thanks": sets consent to .disabled and discards held events.
    func disableReporting() {
        lock.lock()
        defer { lock.unlock() }

        // Set state directly to avoid nested lock acquisition
        UserDefaults.standard.set(CrashReportingConsentState.disabled.rawValue, forKey: defaultsKey)
        heldEvents.removeAll()
    }
}
