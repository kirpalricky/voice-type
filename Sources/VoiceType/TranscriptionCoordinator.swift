import Foundation
import AVFoundation
import OSLog

@MainActor
final class TranscriptionCoordinator {
    private let appState: AppState
    private let audioRecorder: AudioRecording
    private let transcriber: Transcribing
    private let polisher: Polishing
    private let glossaryStore: GlossaryStore
    private let historyStore: HistoryStore
    private let logger: OSLog
    private let onHideResultPanel: () -> Void

    private(set) var processingTask: Task<Void, Never>?

    init(
        appState: AppState,
        audioRecorder: AudioRecording,
        transcriber: Transcribing,
        polisher: Polishing,
        glossaryStore: GlossaryStore,
        historyStore: HistoryStore,
        logger: OSLog,
        onHideResultPanel: @escaping () -> Void
    ) {
        self.appState = appState
        self.audioRecorder = audioRecorder
        self.transcriber = transcriber
        self.polisher = polisher
        self.glossaryStore = glossaryStore
        self.historyStore = historyStore
        self.logger = logger
        self.onHideResultPanel = onHideResultPanel
    }

    func startRecording() async {
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

    func stopRecordingAndTranscribe() async {
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

            let glossaryEntries = glossaryStore.entries

            // Layer 1: Apply exact match (case-insensitive, phrase-aware)
            let afterExactMatch = VocabularyMatcher.applyExactMatch(rawTranscript, glossary: glossaryEntries)

            // Layer 2: Apply fuzzy match (with dictionary gate and length-aware threshold)
            let afterFuzzyMatch = VocabularyMatcher.applyFuzzyMatch(afterExactMatch, glossary: glossaryEntries)

            // Layer 3: Polish transcript using on-device Foundation Models with glossary hints
            let glossaryStrings = glossaryEntries.map { entry in
                if entry.variants.isEmpty {
                    return entry.canonical
                } else {
                    return "\(entry.canonical) (also heard as: \(entry.variants.joined(separator: ", ")))"
                }
            }
            appState.statusMessage = "Polishing transcript…"
            let polishedTranscript = try await cancellable { [self] in
                try await self.polisher.polish(afterFuzzyMatch, glossary: glossaryStrings)
            }
            try Task.checkCancellation()
            appState.polishedTranscript = polishedTranscript

            os_log("Transcription pipeline complete: %d chars raw, %d chars after exact, %d chars after fuzzy, %d chars polished", log: self.logger, type: .info, rawTranscript.count, afterExactMatch.count, afterFuzzyMatch.count, polishedTranscript.count)

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
            onHideResultPanel()
        } catch {
            os_log("Transcription error: %@", log: self.logger, type: .error, error.localizedDescription)
            appState.isRecording = false
            appState.isProcessing = false
            appState.processingError = error.localizedDescription
            appState.showingResultPanel = true
        }
    }

    func toggleRecording() async {
        if appState.isRecording {
            await stopRecordingAndTranscribe()
        } else {
            await startRecording()
        }
    }

    func toggleRecordingSync() {
        processingTask = Task {
            await toggleRecording()
        }
    }

    func cancelProcessing() {
        os_log("Cancel requested", log: self.logger, type: .info)
        processingTask?.cancel()
        processingTask = nil
    }

    func stopRecordingSync() {
        processingTask = Task {
            await stopRecordingAndTranscribe()
        }
    }
}
