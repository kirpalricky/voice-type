import SwiftUI
import KeyboardShortcuts
import OSLog

@main
struct VoiceTypeApp: App {
    @State private var appState = AppState()
    @State private var audioRecorder: AudioRecorder?
    @State private var transcriber: Transcriber?
    @State private var glossaryStore: GlossaryStore?
    @State private var resultPanelWindow: ResultPanelWindow?
    @State private var settingsWindow: NSWindow?
    @State private var recordingTimer: Timer?

    private let logger = OSLog(subsystem: "com.voicetype.app", category: "VoiceTypeApp")

    init() {
        setupHotkeys()
        initializeServices()
    }

    var body: some Scene {
        MenuBarExtra("VoiceType", systemImage: menuBarIcon) {
            VoiceTypeMenuView(appState: appState, onSettings: openSettings, onToggleRecording: toggleRecordingSync)
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
            Task {
                await stopRecordingAndTranscribe()
            }
        }
    }

    private func initializeServices() {
        Task {
            // Initialize audio recorder
            self.audioRecorder = AudioRecorder()

            // Initialize transcriber (will load models on first use)
            self.transcriber = Transcriber()

            // Initialize glossary store
            self.glossaryStore = GlossaryStore()

            os_log("Services initialized", log: self.logger, type: .info)
        }
    }

    private func startRecording() async {
        guard let recorder = audioRecorder else {
            os_log("Audio recorder not initialized", log: self.logger, type: .error)
            return
        }

        do {
            appState.isRecording = true
            try await recorder.startRecording()
        } catch {
            os_log("Failed to start recording: %@", log: self.logger, type: .error, error.localizedDescription)
            appState.isRecording = false
        }
    }

    private func stopRecordingAndTranscribe() async {
        guard let recorder = audioRecorder else {
            os_log("Audio recorder not initialized", log: self.logger, type: .error)
            appState.isRecording = false
            return
        }

        defer {
            appState.isRecording = false
        }

        do {
            // Stop recording and get audio samples
            let audioSamples = try await recorder.stopRecording()

            guard !audioSamples.isEmpty else {
                os_log("No audio samples captured", log: self.logger, type: .default)
                return
            }

            // Set processing state
            appState.isProcessing = true
            defer {
                appState.isProcessing = false
            }

            // Initialize transcriber if needed
            if transcriber == nil {
                self.transcriber = Transcriber()
            }

            guard let transcriber = transcriber else {
                os_log("Transcriber not initialized", log: self.logger, type: .error)
                return
            }

            // Initialize model on first use
            try await transcriber.initialize()

            // Transcribe audio
            let rawTranscript = try await transcriber.transcribe(audioSamples)
            appState.rawTranscript = rawTranscript
            print("RAW: \(rawTranscript)")

            // Get glossary store (should be initialized by now)
            let glossaryStore = self.glossaryStore ?? GlossaryStore()
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
            let polishedTranscript = try await Enhancer.polish(afterFuzzyMatch, glossary: glossaryStrings)
            appState.polishedTranscript = polishedTranscript
            print("POLISHED: \(polishedTranscript)")

            os_log("Raw transcript: %@", log: self.logger, type: .info, rawTranscript)
            os_log("After exact match: %@", log: self.logger, type: .info, afterExactMatch)
            os_log("After fuzzy match: %@", log: self.logger, type: .info, afterFuzzyMatch)
            os_log("Polished transcript: %@", log: self.logger, type: .info, polishedTranscript)

            // Show result panel when polished result is ready
            appState.showingResultPanel = true
            appState.elapsedRecordingSeconds = 0

        } catch {
            os_log("Transcription error: %@", log: self.logger, type: .error, error.localizedDescription)
            appState.isProcessing = false
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
        Task {
            await toggleRecording()
        }
    }

    private func showResultPanel() {
        if resultPanelWindow == nil {
            resultPanelWindow = ResultPanelWindow(appState: appState)
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

    private func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView(glossaryStore: glossaryStore ?? GlossaryStore())
            let hostingController = NSHostingController(rootView: settingsView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "VoiceType Settings"
            window.setFrameAutosaveName("SettingsWindow")
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct VoiceTypeMenuView: View {
    var appState: AppState
    var onSettings: () -> Void
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
