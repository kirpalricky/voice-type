import Foundation
import Sentry

enum SentryConfig {
    /// Tracks whether Sentry SDK has been successfully initialized.
    private(set) static var isConfigured = false

    /// Second hub for non-fatal error reporting to a separate DSN (errors project).
    /// Built lazily on first access if errorsDSN is configured.
    private(set) static var errorsHub: SentryHub?

    /// Initializes the Sentry SDK with privacy-critical settings applied.
    ///
    /// Resolves DSN from environment variable (SENTRY_DSN) first, then falls back to
    /// Secrets.dsn. If DSN is empty/missing, logs to DiagnosticLogger and skips initialization.
    /// Also initializes a second hub for non-fatal errors if errorsDSN is configured.
    static func start() {
        let crashesDSN: String
        if let envDsn = ProcessInfo.processInfo.environment["SENTRY_DSN"], !envDsn.isEmpty {
            crashesDSN = envDsn
        } else {
            crashesDSN = Secrets.dsn
        }

        guard !crashesDSN.isEmpty else {
            DiagnosticLogger.shared.log("Sentry crash reporting disabled: no DSN configured")
            return
        }

        // Initialize primary SDK for native crash reporting
        SentrySDK.start { options in
            configurePrivacyOptions(options, dsn: crashesDSN)
        }

        // Initialize secondary hub for non-fatal errors if errorsDSN is configured
        if !Secrets.errorsDSN.isEmpty {
            let errorOptions = Options()
            configurePrivacyOptions(errorOptions, dsn: Secrets.errorsDSN)
            if let client = SentryClient(options: errorOptions) {
                self.errorsHub = SentryHub(client: client, andScope: nil)
            }
        }

        isConfigured = true
        DiagnosticLogger.shared.log("Sentry crash reporting initialized")
    }

    /// Configures privacy-critical options for an Options instance.
    /// This logic is shared between the primary SDK and the secondary errors hub.
    private static func configurePrivacyOptions(_ options: Options, dsn: String) {
        options.dsn = dsn

        // Disable telemetry collection.
        options.enableAutoSessionTracking = false
        options.tracesSampleRate = 0
        options.sendDefaultPii = false
        options.enableFileIOTracing = false

        #if os(iOS) || os(tvOS)
        options.attachScreenshot = false
        options.attachViewHierarchy = false
        options.enableUserInteractionTracing = false
        #endif

        // beforeSend: apply consent gating and redaction.
        options.beforeSend = { event in
            // Redact user paths.
            var redactedEvent = event
            redactedEvent = redactEventPaths(redactedEvent)

            // Null out sensitive fields defensively.
            redactedEvent.serverName = nil
            if redactedEvent.context != nil {
                var mutableContext = redactedEvent.context ?? [:]
                mutableContext["device"] = nil
                redactedEvent.context = mutableContext
            }

            // Strip user identity and IP address unconditionally.
            // This must happen regardless of consent state to prevent leaking stable identifiers
            // and IP addresses in events held in the holding-pen or dropped events.
            redactedEvent.user = nil

            // Remove identity-related tags.
            if let tags = redactedEvent.tags {
                // Filter out tags that carry identity information.
                let identityTagKeys = Set(["user.id"])
                let filteredTags = tags.filter { !identityTagKeys.contains($0.key) }
                redactedEvent.tags = filteredTags.isEmpty ? nil : filteredTags
            }

            // Gate by consent state.
            switch CrashReportingConsentManager.shared.state {
            case .disabled:
                return nil
            case .unset:
                CrashReportingConsentManager.shared.holdEvent(redactedEvent)
                return nil
            case .enabled:
                return redactedEvent
            }
        }

        // beforeBreadcrumb: allowlist only safe categories and redact paths.
        options.beforeBreadcrumb = { crumb in
            // Allowlist of acceptable breadcrumb categories.
            let allowedCategories = ["app.lifecycle"]
            guard allowedCategories.contains(crumb.category) else {
                return nil
            }

            // Redact paths in breadcrumb message.
            if let message = crumb.message {
                crumb.message = PathRedaction.redact(message)
            }

            return crumb
        }
    }

    /// Redacts user home directory paths from an event's string-valued fields.
    private static func redactEventPaths(_ event: Sentry.Event) -> Sentry.Event {
        // Redact event message.
        if let message = event.message {
            let redactedFormatted = PathRedaction.redact(message.formatted)
            event.message = SentryMessage(formatted: redactedFormatted)
        }

        // Redact exception values.
        if let exceptions = event.exceptions {
            for exception in exceptions {
                if let value = exception.value {
                    exception.value = PathRedaction.redact(value)
                }
            }
        }

        // Redact breadcrumb messages.
        if let breadcrumbs = event.breadcrumbs {
            for breadcrumb in breadcrumbs {
                if let message = breadcrumb.message {
                    breadcrumb.message = PathRedaction.redact(message)
                }
            }
        }

        // Redact extra dictionary string values.
        if var extra = event.extra {
            for (key, value) in extra {
                if let stringValue = value as? String {
                    extra[key] = PathRedaction.redact(stringValue)
                }
            }
            event.extra = extra
        }

        return event
    }
}
