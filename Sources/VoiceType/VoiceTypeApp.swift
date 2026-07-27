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
    @State private var processingTask: Task<Void, Never>?
    @State private var hotkeyManager: HotkeyManager?

    private let logger = OSLog(subsystem: "com.voicetype.app", category: "VoiceTypeApp")

    init() {
        hotkeyManager = HotkeyManager(
            onKeyDown: { [self] in
                Task {
                    await self.startRecording()
                }
            },
            onKeyUp: { [self] in
                self.processingTask = Task {
                    await self.stopRecordingAndTranscribe()
                }
            }
        )
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
            return "waveform.circle.fill"
        } else if appState.isProcessing {
            return "arrow.triangle.2.circlepath"
        } else {
            return "waveform"
        }
    }

    private func startRecording() async {
        guard await hasMicrophoneAccess() else {
            os_log("Microphone access not granted", log: self.logger, type: .error)
            appState.processingError = "Microphone access is required. Enable it in System Settings > Privacy & Security > Microphone."
            appState.showingResultPanel = true
            return
        }

        do {
            appState.isRecording = true
            appState.processingError = nil
            appState.resetLevels()
            try await audioRecorder.startRecording(onBands: { [appState] bands in
                Task { @MainActor in
                    appState.latestBands = bands
                }
            })
        } catch {
            os_log("Failed to start recording: %@", log: self.logger, type: .error, error.localizedDescription)
            appState.isRecording = false
            appState.processingError = "Couldn't start recording: \(error.localizedDescription)"
            appState.showingResultPanel = true
        }
    }

    /// Ensures the microphone TCC prompt (if any) is fully resolved before the audio engine
    /// starts. Starting the engine while a permission dialog is still pending races the OS
    /// grant and silently captures nothing for the whole recording.
    private func hasMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            if granted {
                // The HAL input route isn't always live the instant the TCC prompt resolves;
                // give it a moment before the caller starts the engine.
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            return granted
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }


    private func stopRecordingAndTranscribe() async {
        do {
            // Stop recording and get audio samples
            let audioSamples = try await audioRecorder.stopRecording()
            appState.isRecording = false

            guard !audioSamples.isEmpty else {
                os_log("No audio samples captured", log: self.logger, type: .error)
                appState.processingError = "No audio was captured. Check your microphone and try again."
                appState.showingResultPanel = true
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
            try await cancellable { [transcriber, appState] in
                try await transcriber.initialize(onProgress: { status in
                    Task { @MainActor in
                        appState.statusMessage = status
                    }
                })
            }
            try Task.checkCancellation()

            // Transcribe audio
            appState.statusMessage = "Transcribing…"
            let rawTranscript = try await cancellable { [transcriber] in
                try await transcriber.transcribe(audioSamples)
            }
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
            let polishedTranscript = try await cancellable {
                try await Enhancer.polish(afterFuzzyMatch, glossary: glossaryStrings)
            }
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
            // `showingResultPanel` may already be false here (the panel was opened via the
            // isRecording->showResultPanel path, not this flag), so the onChange that would
            // normally hide the window never fires. Hide it directly so cancelling doesn't
            // leave a blank panel on screen.
            resultPanelWindow?.hide()
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
    var onToggleRecording: () -> Void

    @State private var recordingRowHovering = false
    @State private var historyRowHovering = false
    @State private var settingsRowHovering = false
    @State private var quitRowHovering = false

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
                    Text(appState.isRecording ? "Stop Recording" : "Start Recording")
                        .font(.system(size: 13))
                    Spacer()
                    if !recordingHotkeyHint.isEmpty {
                        Text(recordingHotkeyHint)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
