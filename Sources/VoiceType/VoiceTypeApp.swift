import SwiftUI
import KeyboardShortcuts
import OSLog
import AVFoundation

@main
struct VoiceTypeApp: App {
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

    private let logger = OSLog(subsystem: "com.voicetype.app", category: "VoiceTypeApp")

    init() {
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
            logger: OSLog(subsystem: "com.voicetype.app", category: "TranscriptionCoordinator"),
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
        MenuBarExtra("VoiceType", systemImage: menuBarIcon) {
            VoiceTypeMenuView(
                appState: appState,
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
            let settingsView = SettingsView(glossaryStore: glossaryStore, historyStore: historyStore, initialSection: section)
            let hostingController = NSHostingController(rootView: settingsView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "VoiceType Settings"
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

struct VoiceTypeMenuView: View {
    var appState: AppState
    var onSettings: () -> Void
    var onShowHistory: () -> Void
    var onShowAbout: () -> Void
    var onToggleRecording: () -> Void

    @State private var recordingRowHovering = false
    @State private var historyRowHovering = false
    @State private var settingsRowHovering = false
    @State private var quitRowHovering = false
    @State private var versionRowHovering = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
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
            Text("VoiceType")
                .font(.system(size: 13, weight: .semibold))
                .padding(.vertical, 6)
                .padding(.horizontal, 12)

            Divider()

            // Start/Stop Recording button
            Button(action: onToggleRecording) {
                HStack {
                    Text(appState.isModelLoading ? "Loading speech model…" : (appState.isRecording ? "Stop Recording" : "Start Recording"))
                        .font(.system(size: 13))
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
            .help(appState.isModelLoading ? appState.modelLoadStatus : "")

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

            // Version button
            Button(action: onShowAbout) {
                HStack {
                    Text("Version \(appVersion) (\(appBuild))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(versionRowHovering ? Color.gray.opacity(0.15) : Color.clear)
            .onHover { hovering in
                versionRowHovering = hovering
            }

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
