import SwiftUI
import KeyboardShortcuts
import OSLog

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
    @State private var processingTask: Task<Void, Never>?

    private let logger = OSLog(subsystem: "com.voicetype.app", category: "VoiceTypeApp")

    init() {
        setupHotkeys()
    }

    var body: some Scene {
        MenuBarExtra("VoiceType", systemImage: menuBarIcon) {
            VoiceTypeMenuView(
                appState: appState,
                onSettings: { openSettings() },
                onShowHistory: openHistory,
                onToggleRecording: toggleRecordingSync
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
            return "mic.fill"
        } else if appState.isProcessing {
            return "arrow.triangle.2.circlepath"
        } else {
            return "mic"
        }
    }

    private func setupHotkeys() {
        // Listen for push-to-talk key down
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [self] in
            os_log("Hotkey pressed - starting recording", log: self.logger, type: .info)
            Task {
                await startRecording()
            }
        }

        // Listen for push-to-talk key up
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [self] in
            os_log("Hotkey released - stopping recording", log: self.logger, type: .info)
            processingTask = Task {
                await stopRecordingAndTranscribe()
            }
        }
    }

    private func startRecording() async {
        do {
            appState.isRecording = true
            appState.processingError = nil
            appState.levelHistory = Array(repeating: 0, count: appState.levelHistory.count)
            try await audioRecorder.startRecording(onLevel: { [appState] level in
                Task { @MainActor in
                    appState.pushLevel(level)
                }
            })
        } catch {
            os_log("Failed to start recording: %@", log: self.logger, type: .error, error.localizedDescription)
            appState.isRecording = false
            appState.processingError = "Couldn't start recording: \(error.localizedDescription)"
            appState.showingResultPanel = true
        }
    }

    private func stopRecordingAndTranscribe() async {
        do {
            // Stop recording and get audio samples
            let audioSamples = try await audioRecorder.stopRecording()
            appState.isRecording = false
            appState.audioLevel = 0

            guard !audioSamples.isEmpty else {
                os_log("No audio samples captured", log: self.logger, type: .default)
                appState.showingResultPanel = false
                return
            }

            // Set processing state
            appState.isProcessing = true
            defer {
                appState.isProcessing = false
                appState.statusMessage = ""
            }

            // Initialize model on first use
            appState.statusMessage = "Loading speech model…"
            try await transcriber.initialize(onProgress: { [appState] status in
                Task { @MainActor in
                    appState.statusMessage = status
                }
            })
            try Task.checkCancellation()

            // Transcribe audio
            appState.statusMessage = "Transcribing…"
            let rawTranscript = try await transcriber.transcribe(audioSamples)
            try Task.checkCancellation()
            appState.rawTranscript = rawTranscript
            print("RAW: \(rawTranscript)")

            let glossaryEntries = glossaryStore.entries

            // Layer 1: Apply exact match (case-insensitive, phrase-aware)
            let afterExactMatch = VocabularyMatcher.applyExactMatch(rawTranscript, glossary: glossaryEntries)
            print("AFTER-EXACT: \(afterExactMatch)")

            // Layer 2: Apply fuzzy match (with dictionary gate and length-aware threshold)
            let afterFuzzyMatch = VocabularyMatcher.applyFuzzyMatch(afterExactMatch, glossary: glossaryEntries)
            print("AFTER-FUZZY: \(afterFuzzyMatch)")

            // Layer 3: Polish transcript using on-device Foundation Models with glossary hints
            let glossaryStrings = glossaryEntries.map { entry in
                if entry.variants.isEmpty {
                    return entry.canonical
                } else {
                    return "\(entry.canonical) (also heard as: \(entry.variants.joined(separator: ", ")))"
                }
            }
            appState.statusMessage = "Polishing transcript…"
            let polishedTranscript = try await Enhancer.polish(afterFuzzyMatch, glossary: glossaryStrings)
            try Task.checkCancellation()
            appState.polishedTranscript = polishedTranscript
            print("POLISHED: \(polishedTranscript)")

            os_log("Raw transcript: %@", log: self.logger, type: .info, rawTranscript)
            os_log("After exact match: %@", log: self.logger, type: .info, afterExactMatch)
            os_log("After fuzzy match: %@", log: self.logger, type: .info, afterFuzzyMatch)
            os_log("Polished transcript: %@", log: self.logger, type: .info, polishedTranscript)

            historyStore.addEntry(
                rawTranscript: rawTranscript,
                polishedTranscript: polishedTranscript,
                audioSamples: audioSamples,
                sampleRate: 16000
            )

            // Show result panel when polished result is ready
            appState.showingResultPanel = true
            appState.elapsedRecordingSeconds = 0

        } catch is CancellationError {
            os_log("Processing cancelled by user", log: self.logger, type: .info)
            appState.isRecording = false
            appState.isProcessing = false
            appState.showingResultPanel = false
        } catch {
            os_log("Transcription error: %@", log: self.logger, type: .error, error.localizedDescription)
            appState.isRecording = false
            appState.isProcessing = false
            appState.processingError = error.localizedDescription
            appState.showingResultPanel = true
        }
    }

    private func toggleRecording() async {
        if appState.isRecording {
            await stopRecordingAndTranscribe()
        } else {
            await startRecording()
        }
    }

    private func toggleRecordingSync() {
        processingTask = Task {
            await toggleRecording()
        }
    }

    private func cancelProcessing() {
        os_log("Cancel requested", log: self.logger, type: .info)
        processingTask?.cancel()
        processingTask = nil
    }

    private func stopRecordingSync() {
        processingTask = Task {
            await stopRecordingAndTranscribe()
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
                onCancel: cancelProcessing,
                onStopRecording: stopRecordingSync,
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

    private func openSettings(initialTab: Int = 0) {
        if settingsWindow == nil {
            let settingsView = SettingsView(glossaryStore: glossaryStore, historyStore: historyStore, initialTab: initialTab)
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
        openSettings(initialTab: 2)
    }
}

struct VoiceTypeMenuView: View {
    var appState: AppState
    var onSettings: () -> Void
    var onShowHistory: () -> Void
    var onToggleRecording: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("VoiceType")
                .font(.system(.headline))
                .padding(.vertical, 8)
                .padding(.horizontal, 12)

            Divider()

            Button(action: onToggleRecording) {
                HStack {
                    Text(appState.isRecording ? "Stop Recording" : "Start Recording")
                    Spacer()
                    Text("⌘⇧D")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)

            Button(action: onShowHistory) {
                HStack {
                    Text("History…")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)

            Button(action: onSettings) {
                HStack {
                    Text("Settings…")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)

            Divider()

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack {
                    Text("Quit")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
        }
        .frame(minWidth: 200)
    }
}
