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

    /// Kicks off model download/load in the background as soon as the app launches, instead
    /// of waiting for the first `stopRecordingAndTranscribe()` call, so a fresh install isn't
    /// stuck waiting on a multi-hundred-MB download mid-recording. The later call in
    /// `stopRecordingAndTranscribe()` is a fast no-op once this succeeds, and simply retries
    /// if this failed. Note `Transcriber.initialize()`'s `guard !isInitialized` only protects
    /// against *sequential* re-entry, not concurrent calls (the flag flips after the download
    /// completes, not before) — that's fine today because `startRecording()` is gated on
    /// `isModelLoading` so nothing can reach the second call path until this one has finished,
    /// but don't assume it'd be safe to call `initialize()` from two places concurrently.
    func preloadModel() async {
        DiagnosticLogger.shared.log("TranscriptionCoordinator.preloadModel() entered")
        do {
            try await transcriber.initialize(onProgress: { [appState] status in
                Task { @MainActor in
                    appState.modelLoadStatus = status
                }
            })
            DiagnosticLogger.shared.log("TranscriptionCoordinator.preloadModel() succeeded")
        } catch {
            os_log("Model preload failed: %@", log: self.logger, type: .error, error.localizedDescription)
            DiagnosticLogger.shared.log("TranscriptionCoordinator.preloadModel() failed: \(error)")
        }
        appState.isModelLoading = false
        appState.modelLoadStatus = ""
    }

    func startRecording() async {
        DiagnosticLogger.shared.log("TranscriptionCoordinator.startRecording() entered")
        guard !appState.isModelLoading else {
            DiagnosticLogger.shared.log("TranscriptionCoordinator.startRecording() blocked - model still loading")
            return
        }
        guard await hasMicrophoneAccess() else {
            DiagnosticLogger.shared.log("TranscriptionCoordinator.startRecording() - mic access denied")
            os_log("Microphone access not granted", log: self.logger, type: .error)
            appState.processingError = "Microphone access is required. Enable it in System Settings > Privacy & Security > Microphone."
            appState.showingResultPanel = true
            return
        }

        do {
            appState.isRecording = true
            appState.processingError = nil
            appState.resetLevels()
            DiagnosticLogger.shared.log("TranscriptionCoordinator.startRecording() calling audioRecorder.startRecording()")
            try await audioRecorder.startRecording(onBands: { [appState] bands in
                Task { @MainActor in
                    appState.latestBands = bands
                }
            })
            DiagnosticLogger.shared.log("TranscriptionCoordinator.startRecording() audioRecorder.startRecording() succeeded, isRecording=\(appState.isRecording)")
        } catch {
            DiagnosticLogger.shared.log("TranscriptionCoordinator.startRecording() audioRecorder.startRecording() THREW: \(error)")
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
        DiagnosticLogger.shared.log("TranscriptionCoordinator.stopRecordingAndTranscribe() entered")
        do {
            // Stop recording and get audio samples
            let audioSamples = try await audioRecorder.stopRecording()
            DiagnosticLogger.shared.log("TranscriptionCoordinator.stopRecordingAndTranscribe() got \(audioSamples.count) samples")
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

            // Run transcription pipeline
            appState.statusMessage = "Transcribing…"
            let glossaryEntries = glossaryStore.entries
            let pipelineResult = try await cancellable { [transcriber, polisher] in
                try await TranscriptionPipeline.run(
                    audioSamples: audioSamples,
                    transcriber: transcriber,
                    polisher: polisher,
                    glossary: glossaryEntries
                )
            }
            try Task.checkCancellation()

            appState.rawTranscript = pipelineResult.rawTranscript
            appState.polishedTranscript = pipelineResult.polishedTranscript

            os_log("Transcription pipeline complete: %d chars raw, %d chars polished", log: self.logger, type: .info, pipelineResult.rawTranscript.count, pipelineResult.polishedTranscript.count)

            historyStore.addEntry(
                rawTranscript: pipelineResult.rawTranscript,
                polishedTranscript: pipelineResult.polishedTranscript,
                audioSamples: audioSamples,
                sampleRate: 16000
            )

            // Show result panel when polished result is ready
            appState.showingResultPanel = true
            appState.elapsedRecordingSeconds = 0

        } catch is CancellationError {
            DiagnosticLogger.shared.log("TranscriptionCoordinator.stopRecordingAndTranscribe() CAUGHT CancellationError")
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
            DiagnosticLogger.shared.log("TranscriptionCoordinator.stopRecordingAndTranscribe() CAUGHT error: \(error)")
            os_log("Transcription error: %@", log: self.logger, type: .error, error.localizedDescription)
            appState.isRecording = false
            appState.isProcessing = false
            appState.processingError = error.localizedDescription
            appState.showingResultPanel = true
        }
    }

    func toggleRecording() async {
        DiagnosticLogger.shared.log("TranscriptionCoordinator.toggleRecording() entered, isRecording=\(appState.isRecording)")
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
        // Guards the case where `startRecording()` no-op'd (e.g. blocked on
        // `isModelLoading`) so recording never actually began: without this, a hotkey
        // key-up or the panel's Stop button would still call `stopRecordingAndTranscribe()`,
        // which throws `engineNotInitialized` since the audio engine was never created,
        // popping a spurious error panel.
        guard appState.isRecording else { return }
        processingTask = Task {
            await stopRecordingAndTranscribe()
        }
    }
}
