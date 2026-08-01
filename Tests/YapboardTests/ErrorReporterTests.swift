import Testing
import Foundation
@testable import Yapboard

@Suite(.serialized)
struct ErrorReporterTests {
    // MARK: - Setup/Teardown helpers

    private func clearTally() {
        ErrorReporter.shared._clearTallyForTesting()
    }

    private func saveConsentState() -> CrashReportingConsentState {
        return CrashReportingConsentManager.shared.state
    }

    private func restoreConsentState(_ state: CrashReportingConsentState) {
        CrashReportingConsentManager.shared.state = state
    }

    // MARK: - Dedup/Count Tests

    @Test
    func dedupAndCount_SameErrorTwice_CountIncrementsToTwo() {
        clearTally()
        defer { clearTally() }

        let reporter = ErrorReporter.shared
        let error = NSError(domain: "TestDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "Test error"])

        reporter.report(error, site: "testSite")
        #expect(reporter.tally.count == 1)

        let tallyValue = reporter.tally.values.first
        #expect(tallyValue?.count == 1)

        reporter.report(error, site: "testSite")
        #expect(reporter.tally.count == 1, "Should still have only one entry")

        let updatedValue = reporter.tally.values.first
        #expect(updatedValue?.count == 2, "Count should be incremented to 2")
    }

    @Test
    func dedupAndCount_DifferentDomains_CreatesSeperateEntries() {
        clearTally()
        defer { clearTally() }

        let reporter = ErrorReporter.shared
        let error1 = NSError(domain: "Domain1", code: 42, userInfo: [NSLocalizedDescriptionKey: "Error 1"])
        let error2 = NSError(domain: "Domain2", code: 42, userInfo: [NSLocalizedDescriptionKey: "Error 2"])

        reporter.report(error1, site: "testSite")
        reporter.report(error2, site: "testSite")

        #expect(reporter.tally.count == 2, "Should have two separate entries for different domains")
    }

    @Test
    func dedupAndCount_DifferentCodes_CreatesSeperateEntries() {
        clearTally()
        defer { clearTally() }

        let reporter = ErrorReporter.shared
        let error1 = NSError(domain: "TestDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Error 1"])
        let error2 = NSError(domain: "TestDomain", code: 2, userInfo: [NSLocalizedDescriptionKey: "Error 2"])

        reporter.report(error1, site: "testSite")
        reporter.report(error2, site: "testSite")

        #expect(reporter.tally.count == 2, "Should have two separate entries for different codes")
    }

    @Test
    func dedupAndCount_DifferentSites_CreatesSeperateEntries() {
        clearTally()
        defer { clearTally() }

        let reporter = ErrorReporter.shared
        let error = NSError(domain: "TestDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "Error"])

        reporter.report(error, site: "site1")
        reporter.report(error, site: "site2")

        #expect(reporter.tally.count == 2, "Should have two separate entries for different sites")
    }

    // MARK: - firstSeen/lastSeen Tests

    @Test
    func timing_FirstReportSetsFirstAndLastSeen() {
        clearTally()
        defer { clearTally() }

        let reporter = ErrorReporter.shared
        let error = NSError(domain: "TestDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "Test error"])

        let beforeReport = Date()
        reporter.report(error, site: "testSite")
        let afterReport = Date()

        #expect(reporter.tally.count == 1)
        let value = reporter.tally.values.first
        #expect(value != nil)
        #expect(value!.firstSeen >= beforeReport && value!.firstSeen <= afterReport)
        #expect(value!.lastSeen >= beforeReport && value!.lastSeen <= afterReport)
        #expect(value!.firstSeen == value!.lastSeen, "On first report, firstSeen should equal lastSeen")
    }

    @Test
    func timing_SecondReportUpdatesLastSeenButNotFirstSeen() {
        clearTally()
        defer { clearTally() }

        let reporter = ErrorReporter.shared
        let error = NSError(domain: "TestDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "Test error"])

        reporter.report(error, site: "testSite")
        let firstValue = reporter.tally.values.first!
        let originalFirstSeen = firstValue.firstSeen

        // Small delay to ensure time difference
        Thread.sleep(forTimeInterval: 0.01)

        reporter.report(error, site: "testSite")
        let secondValue = reporter.tally.values.first!

        #expect(secondValue.firstSeen == originalFirstSeen, "firstSeen should not change on second report")
        #expect(secondValue.lastSeen > originalFirstSeen, "lastSeen should be updated to later time")
    }

    // MARK: - Flush Tests

    @Test
    func flush_ClearsTheTally() {
        clearTally()
        defer { clearTally() }

        let reporter = ErrorReporter.shared
        let error = NSError(domain: "TestDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "Test error"])
        reporter.report(error, site: "testSite")

        #expect(reporter.tally.count == 1)
        reporter.flush()
        #expect(reporter.tally.isEmpty, "Tally should be empty after flush")
    }

    @Test
    func flush_EmptyTallyIsNoOp() {
        clearTally()
        defer { clearTally() }

        let reporter = ErrorReporter.shared
        #expect(reporter.tally.isEmpty)
        reporter.flush() // Should not crash
        #expect(reporter.tally.isEmpty)
    }

    @Test
    func flush_MultipleTimes_IsIdempotent() {
        clearTally()
        defer { clearTally() }

        let reporter = ErrorReporter.shared
        let error = NSError(domain: "TestDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "Test error"])
        reporter.report(error, site: "testSite")

        reporter.flush()
        #expect(reporter.tally.isEmpty)

        // Second flush should also work without issues
        reporter.flush()
        #expect(reporter.tally.isEmpty)
    }

    // MARK: - Consent Tests
    // Note: These tests verify that ErrorReporter.report() respects the consent state.
    // The consent state is checked in ErrorReporter.report() via the guard clause:
    // guard CrashReportingConsentManager.shared.state != .disabled else { return }
    // This ensures errors aren't tallied when consent is explicitly disabled.

    @Test
    func consent_DisabledSkipsReporting() {
        clearTally()
        defer { clearTally() }

        let reporter = ErrorReporter.shared
        let initialState = saveConsentState()
        defer { restoreConsentState(initialState) }

        // Directly test the behavior without using UserDefaults operations that interfere
        CrashReportingConsentManager.shared.state = .disabled

        let error = NSError(domain: "TestDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "Test error"])
        reporter.report(error, site: "testSite")

        #expect(reporter.tally.isEmpty, "Errors should not be added to tally when consent is .disabled")

        // Restore original state
        restoreConsentState(initialState)
    }

    // MARK: - CrashReportingConsentManager Tests
    // Merged into this suite (rather than a separate file) because both test groups mutate the
    // same UserDefaults-backed CrashReportingConsentManager singleton; Swift Testing's `.serialized`
    // only prevents parallelism *within* a suite, not across suites, so keeping them in separate
    // files caused real cross-suite races (one suite's state mutation observed mid-test by the other).

    @Test
    func consentManager_state_DefaultIsUnset() {
        UserDefaults.standard.removeObject(forKey: "crashReportingConsentState")
        defer { UserDefaults.standard.removeObject(forKey: "crashReportingConsentState") }

        let manager = CrashReportingConsentManager.shared
        #expect(manager.state == .unset)
    }

    @Test
    func consentManager_state_PersistsToUserDefaults() {
        UserDefaults.standard.removeObject(forKey: "crashReportingConsentState")
        defer { UserDefaults.standard.removeObject(forKey: "crashReportingConsentState") }

        let manager = CrashReportingConsentManager.shared
        manager.state = .enabled
        #expect(manager.state == .enabled)

        manager.state = .disabled
        #expect(manager.state == .disabled)
    }

    @Test
    func consentManager_recordSentEvent_StoresEventSummary() {
        UserDefaults.standard.removeObject(forKey: "crashReportingLastSentEventSummary")
        defer { UserDefaults.standard.removeObject(forKey: "crashReportingLastSentEventSummary") }

        let manager = CrashReportingConsentManager.shared
        manager.recordSentEvent(message: "Test error message")

        let summary = manager.lastSentEventSummary
        #expect(summary != nil)
        #expect(summary?.contains("Test error message") == true)
    }

    @Test
    func consentManager_disableReporting_SetsStateToDisabled() {
        UserDefaults.standard.removeObject(forKey: "crashReportingConsentState")
        defer { UserDefaults.standard.removeObject(forKey: "crashReportingConsentState") }

        let manager = CrashReportingConsentManager.shared
        manager.state = .unset

        manager.disableReporting()
        #expect(manager.state == .disabled)
    }

    @Test
    func consentManager_consentState_EnumRawValues() {
        #expect(CrashReportingConsentState.unset.rawValue == "unset")
        #expect(CrashReportingConsentState.enabled.rawValue == "enabled")
        #expect(CrashReportingConsentState.disabled.rawValue == "disabled")
    }
}
