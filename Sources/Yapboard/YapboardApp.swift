import SwiftUI
import KeyboardShortcuts
import OSLog
import AVFoundation
import Combine
import Sparkle
import Observation
import AppKit
import Sentry

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var consentNotificationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check if we should show consent dialog at launch
        // (e.g., after a crash on previous run, or held events from non-fatal errors)
        if CrashReportingConsentManager.shared.shouldShowConsentDialog {
            showCrashReportingConsentDialog()
        }

        // Observe notification for mid-session consent prompt (triggered by first non-fatal error)
        consentNotificationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("com.yapboard.crashReportingConsentPromptNeeded"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showCrashReportingConsentDialog()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ErrorReporter.shared.flush()

        // Clean up observer
        if let observer = consentNotificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func showCrashReportingConsentDialog() {
        let alert = NSAlert()
        alert.messageText = "Yapboard hit a problem."
        alert.informativeText = "Help improve it by sending anonymized crash & error reports? No transcript or personal content is ever included."
        alert.addButton(withTitle: "Enable Reporting")
        alert.addButton(withTitle: "No Thanks")
        alert.alertStyle = .informational

        // Ensure the alert appears on top of other windows
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            // User clicked "Enable Reporting"
            CrashReportingConsentManager.shared.enableReporting()
            DiagnosticLogger.shared.log("Crash reporting consent: ENABLED")
        case .alertSecondButtonReturn:
            // User clicked "No Thanks"
            CrashReportingConsentManager.shared.disableReporting()
            DiagnosticLogger.shared.log("Crash reporting consent: DISABLED")
        default:
            break
        }
    }
}

@Observable
final class UpdaterViewModel: NSObject {
    private let updaterController: SPUStandardUpdaterController
    var canCheckForUpdates = false
    private var cancellables = Set<AnyCancellable>()

    override init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
            .store(in: &cancellables)
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }
}

@main
struct YapboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var appState = AppState()
    @State private var audioRecorder = AudioRecorder()
    @State private var transcriber = Transcriber()
    @State private var glossaryStore = GlossaryStore()
    @State private var historyStore = HistoryStore()
    @State private var resultPanelWindow: ResultPanelWindow?
    @State private var settingsWindow: NSWindow?
    @State private var recordingTimer: Timer?
    @State private var transcriptionCoordinator: TranscriptionCoordinator?
    @State private var hotkeyManager: HotkeyManager?
    @State private var updaterViewModel = UpdaterViewModel()

    private let logger = OSLog(subsystem: "com.yapboard.app", category: "YapboardApp")

    init() {
        SentryConfig.start()

        // Initialize crash context with memory info and permissions
        CrashContext.updateMemoryContext()
        CrashContext.updatePermissionsContext()

        // Assigning through the property name (`self.foo = ...`) inside init() does not
        // reliably install the value into @State's real backing storage — reads of the same
        // property later in this same init(), or from closures capturing self here, can see
        // the pre-assignment (nil) value. Assigning through the underscore-prefixed backing
        // storage (`_foo = State(initialValue:)`) is the correct way to give a @State property
        // a value computed from other properties inside init().
        let coordinator = TranscriptionCoordinator(
            appState: appState,
            audioRecorder: audioRecorder,
            transcriber: transcriber,
            polisher: FoundationModelsPolisher(),
            glossaryStore: glossaryStore,
            historyStore: historyStore,
            logger: OSLog(subsystem: "com.yapboard.app", category: "TranscriptionCoordinator"),
            onHideResultPanel: { [self] in resultPanelWindow?.hide() }
        )
        _transcriptionCoordinator = State(initialValue: coordinator)

        _hotkeyManager = State(initialValue: HotkeyManager(
            onKeyDown: { [self] in
                Task {
                    await self.transcriptionCoordinator?.startRecording()
                }
            },
            onKeyUp: { [self] in
                self.transcriptionCoordinator?.stopRecordingSync()
            }
        ))

        // Start downloading/loading the Parakeet model as soon as the app launches instead of
        // waiting for the first recording, so a fresh install isn't stuck waiting mid-recording.
        Task {
            await coordinator.preloadModel()
        }
    }

    var body: some Scene {
        MenuBarExtra("Yapboard", systemImage: menuBarIcon) {
            YapboardMenuView(
                appState: appState,
                updaterViewModel: updaterViewModel,
                onSettings: { openSettings() },
                onShowHistory: openHistory,
                onShowAbout: { openSettings(section: .about) },
                onToggleRecording: {
                    DiagnosticLogger.shared.log("Menu 'Start/Stop Recording' clicked, transcriptionCoordinator is nil: \(transcriptionCoordinator == nil)")
                    transcriptionCoordinator?.toggleRecordingSync()
                }
            )
        }
        .menuBarExtraStyle(.window)
        .onChange(of: appState.isRecording) { _, newValue in
            if newValue {
                showResultPanel()
                startRecordingTimer()
            } else {
                stopRecordingTimer()
            }
        }
        .onChange(of: appState.showingResultPanel) { _, newValue in
            if newValue {
                showResultPanel()
            } else {
                resultPanelWindow?.hide()
            }
        }
    }

    private var menuBarIcon: String {
        if appState.isRecording {
            return "waveform.circle.fill"
        } else if appState.isModelLoading {
            return "arrow.down.circle"
        } else if appState.isProcessing {
            return "arrow.triangle.2.circlepath"
        } else {
            return "waveform"
        }
    }

    private func dismissError() {
        appState.processingError = nil
        appState.showingResultPanel = false
    }

    private func showResultPanel() {
        if resultPanelWindow == nil {
            resultPanelWindow = ResultPanelWindow(
                appState: appState,
                onCancel: { self.transcriptionCoordinator?.cancelProcessing() },
                onStopRecording: { self.transcriptionCoordinator?.stopRecordingSync() },
                onDismissError: dismissError
            )
        }
        resultPanelWindow?.show()
    }

    private func startRecordingTimer() {
        appState.elapsedRecordingSeconds = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [self] _ in
            guard self.appState.isRecording else {
                self.stopRecordingTimer()
                return
            }
            self.appState.elapsedRecordingSeconds += 1
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func openSettings(section: SettingsSection = .general) {
        if settingsWindow == nil {
            let historyReprocessor = HistoryReprocessor(
                historyStore: historyStore,
                appState: appState,
                transcriber: transcriber,
                polisher: FoundationModelsPolisher(),
                glossaryStore: glossaryStore
            )
            let settingsView = SettingsView(
                glossaryStore: glossaryStore,
                historyStore: historyStore,
                historyReprocessor: historyReprocessor,
                updaterViewModel: updaterViewModel,
                initialSection: section
            )
            let hostingController = NSHostingController(rootView: settingsView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Yapboard Settings"
            window.setFrameAutosaveName("SettingsWindow")
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openHistory() {
        openSettings(section: .history)
    }
}

struct YapboardMenuView: View {
    var appState: AppState
    var updaterViewModel: UpdaterViewModel
    var onSettings: () -> Void
    var onShowHistory: () -> Void
    var onShowAbout: () -> Void
    var onToggleRecording: () -> Void

    @State private var recordingRowHovering = false
    @State private var historyRowHovering = false
    @State private var settingsRowHovering = false
    @State private var quitRowHovering = false
    @State private var updatesRowHovering = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private var modelLoadingLabel: String {
        appState.modelLoadStatus.isEmpty ? "Loading speech model…" : appState.modelLoadStatus
    }

    private var recordingHotkeyHint: String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
            return shortcut.description
        }
        return ""
    }

    private var micDeviceName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "No microphone"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Yapboard")
                .font(.system(size: 13, weight: .semibold))
                .padding(.vertical, 6)
                .padding(.horizontal, 12)

            Divider()

            // Start/Stop Recording button
            Button(action: onToggleRecording) {
                HStack {
                    Text(appState.isModelLoading ? modelLoadingLabel : (appState.isRecording ? "Stop Recording" : "Start Recording"))
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer()
                    if appState.isModelLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else if !recordingHotkeyHint.isEmpty {
                        Text(recordingHotkeyHint)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(appState.isModelLoading)
            .opacity(appState.isModelLoading ? 0.5 : 1.0)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(recordingRowHovering ? Color.gray.opacity(0.15) : Color.clear)
            .onHover { hovering in
                recordingRowHovering = hovering
            }

            // History button
            Button(action: onShowHistory) {
                HStack {
                    Text("History…")
                        .font(.system(size: 13))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(historyRowHovering ? Color.gray.opacity(0.15) : Color.clear)
            .onHover { hovering in
                historyRowHovering = hovering
            }

            // Settings button
            Button(action: onSettings) {
                HStack {
                    Text("Settings…")
                        .font(.system(size: 13))
                    Spacer()
                    Text("⌘,")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(settingsRowHovering ? Color.gray.opacity(0.15) : Color.clear)
            .onHover { hovering in
                settingsRowHovering = hovering
            }

            // Check for Updates button (version shown as trailing secondary text)
            Button(action: { updaterViewModel.checkForUpdates() }) {
                HStack {
                    Text("Check for Updates…")
                        .font(.system(size: 13))
                    Spacer()
                    Text("\(appVersion) (\(appBuild))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!updaterViewModel.canCheckForUpdates)
            .opacity(updaterViewModel.canCheckForUpdates ? 1.0 : 0.5)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(updatesRowHovering ? Color.gray.opacity(0.15) : Color.clear)
            .onHover { hovering in
                updatesRowHovering = hovering
            }

            Divider()

            // Microphone info row (non-interactive)
            HStack(spacing: 6) {
                Text(micDeviceName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: "mic")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)

            Divider()

            // Quit button
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack {
                    Text("Quit")
                        .font(.system(size: 13))
                    Spacer()
                    Text("⌘Q")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(quitRowHovering ? Color.gray.opacity(0.15) : Color.clear)
            .onHover { hovering in
                quitRowHovering = hovering
            }
        }
        .frame(minWidth: 200)
    }
}
