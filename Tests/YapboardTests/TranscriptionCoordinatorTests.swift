import Foundation
import Testing
import OSLog
@testable import Yapboard

// MARK: - Test Doubles

/// Fake audio recorder for testing
final class FakeAudioRecorder: AudioRecording, @unchecked Sendable {
    var stopRecordingResult: [Float] = [0.1, 0.2, 0.3]
    var startRecordingError: Error?
    var stopRecordingError: Error?
    var startRecordingCallCount = 0
    var stopRecordingCallCount = 0

    func startRecording(onBands: (@Sendable ([Float]) -> Void)?) async throws {
        startRecordingCallCount += 1
        if let startRecordingError { throw startRecordingError }
    }

    func stopRecording() async throws -> [Float] {
        stopRecordingCallCount += 1
        if let stopRecordingError { throw stopRecordingError }
        return stopRecordingResult
    }
}

/// Fake transcriber for testing
final class FakeTranscriber: Transcribing, @unchecked Sendable {
    var initializeDelayNanoseconds: UInt64 = 0
    var initializeError: Error?
    var transcribeResult: String = "hello world"
    var transcribeError: Error?
    var initializeCallCount = 0
    var transcribeCallCount = 0

    func initialize(onProgress: (@Sendable (String) -> Void)?) async throws {
        initializeCallCount += 1
        if initializeDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: initializeDelayNanoseconds) }
        if let initializeError { throw initializeError }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        transcribeCallCount += 1
        if let transcribeError { throw transcribeError }
        return transcribeResult
    }
}

/// Fake polisher for testing
final class FakePolisher: Polishing, @unchecked Sendable {
    var polishResult: String = "Hello world."
    var polishError: Error?
    var polishCallCount = 0

    func polish(_ text: String, glossary: [String]) async throws -> String {
        polishCallCount += 1
        if let polishError { throw polishError }
        return polishResult
    }
}

/// Test error for non-cancellation failure cases
enum TestError: Error, Equatable {
    case transcriptionFailed
    case polishingFailed
    case unknown
}

// MARK: - Test Suite

@Suite
@MainActor
struct TranscriptionCoordinatorTests {
    // MARK: - Helpers

    func createTempDir() -> URL {
        let tempDirPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirPath, withIntermediateDirectories: true)
        return tempDirPath
    }

    func createCoordinator(
        audioRecorder: AudioRecording,
        transcriber: Transcribing,
        polisher: Polishing,
        appState: AppState,
        glossaryStore: GlossaryStore,
        historyStore: HistoryStore,
        onHideResultPanel: @escaping () -> Void = {}
    ) -> TranscriptionCoordinator {
        let logger = OSLog(subsystem: "com.yapboard.test", category: "test")
        return TranscriptionCoordinator(
            appState: appState,
            audioRecorder: audioRecorder,
            transcriber: transcriber,
            polisher: polisher,
            glossaryStore: glossaryStore,
            historyStore: historyStore,
            logger: logger,
            onHideResultPanel: onHideResultPanel
        )
    }

    // MARK: - Test 1: Empty Audio Samples

    @Test("Empty audio samples returns error and shows result panel")
    func emptyAudioSamples() async {
        let appState = AppState()
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let glossaryStore = GlossaryStore(baseDirectoryOverride: tempDir)
        let historyStore = HistoryStore(baseDirectoryOverride: tempDir)

        let audioRecorder = FakeAudioRecorder()
        audioRecorder.stopRecordingResult = [] // Empty audio

        let transcriber = FakeTranscriber()
        let polisher = FakePolisher()

        let coordinator = createCoordinator(
            audioRecorder: audioRecorder,
            transcriber: transcriber,
            polisher: polisher,
            appState: appState,
            glossaryStore: glossaryStore,
            historyStore: historyStore
        )

        // Call stopRecordingAndTranscribe directly
        await coordinator.stopRecordingAndTranscribe()

        // Assertions
        #expect(appState.processingError?.contains("No audio was captured") ?? false)
        #expect(appState.showingResultPanel == true)
        #expect(appState.isProcessing == false)
        // Transcriber should never be called if audio is empty
        #expect(transcriber.initializeCallCount == 0)
        #expect(transcriber.transcribeCallCount == 0)
    }

    // MARK: - Test 2: Cancellation at Any Pipeline Stage

    @Test("Cancellation during transcriber initialize hides panel exactly once")
    func cancellationDuringInitialize() async {
        let appState = AppState()
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let glossaryStore = GlossaryStore(baseDirectoryOverride: tempDir)
        let historyStore = HistoryStore(baseDirectoryOverride: tempDir)

        let audioRecorder = FakeAudioRecorder()
        let transcriber = FakeTranscriber()
        transcriber.initializeDelayNanoseconds = 2_000_000_000 // 2 seconds delay

        let polisher = FakePolisher()

        var hideResultPanelCallCount = 0
        let coordinator = createCoordinator(
            audioRecorder: audioRecorder,
            transcriber: transcriber,
            polisher: polisher,
            appState: appState,
            glossaryStore: glossaryStore,
            historyStore: historyStore,
            onHideResultPanel: {
                hideResultPanelCallCount += 1
            }
        )

        // Start the processing task
        let task = Task {
            await coordinator.stopRecordingAndTranscribe()
        }

        // Give it time to start processing
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Cancel the task
        task.cancel()

        // Wait for task completion
        await task.value

        // Assertions
        #expect(hideResultPanelCallCount == 1, "onHideResultPanel should be called exactly once")
        #expect(appState.isRecording == false)
        #expect(appState.isProcessing == false)
        #expect(appState.showingResultPanel == false)
    }

    // MARK: - Test 3: Transcriber Initialize Throws

    @Test("Transcriber initialize error sets processingError and shows panel")
    func transcribeInitializeError() async {
        let appState = AppState()
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let glossaryStore = GlossaryStore(baseDirectoryOverride: tempDir)
        let historyStore = HistoryStore(baseDirectoryOverride: tempDir)

        let audioRecorder = FakeAudioRecorder()
        let transcriber = FakeTranscriber()
        transcriber.initializeError = TestError.transcriptionFailed

        let polisher = FakePolisher()

        let coordinator = createCoordinator(
            audioRecorder: audioRecorder,
            transcriber: transcriber,
            polisher: polisher,
            appState: appState,
            glossaryStore: glossaryStore,
            historyStore: historyStore
        )

        // Call stopRecordingAndTranscribe directly
        await coordinator.stopRecordingAndTranscribe()

        // Assertions
        #expect(appState.processingError != nil)
        #expect(appState.isProcessing == false, "isProcessing should be reset by defer block")
        #expect(appState.showingResultPanel == true)
        // Transcribe should never be called if initialize fails
        #expect(transcriber.transcribeCallCount == 0)
    }

    // MARK: - Test 4: Happy Path

    @Test("Happy path: full pipeline succeeds and adds to history")
    func happyPath() async {
        let appState = AppState()
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let glossaryStore = GlossaryStore(baseDirectoryOverride: tempDir)
        let historyStore = HistoryStore(baseDirectoryOverride: tempDir)

        let audioRecorder = FakeAudioRecorder()
        audioRecorder.stopRecordingResult = [0.1, 0.2, 0.3]

        let transcriber = FakeTranscriber()
        transcriber.transcribeResult = "hello world"

        let polisher = FakePolisher()
        polisher.polishResult = "Hello World."

        let coordinator = createCoordinator(
            audioRecorder: audioRecorder,
            transcriber: transcriber,
            polisher: polisher,
            appState: appState,
            glossaryStore: glossaryStore,
            historyStore: historyStore
        )

        // Initial state
        #expect(historyStore.entries.count == 0)

        // Call stopRecordingAndTranscribe directly
        await coordinator.stopRecordingAndTranscribe()

        // Assertions
        #expect(historyStore.entries.count == 1)
        let entry = historyStore.entries[0]
        #expect(entry.rawTranscript == "hello world")
        #expect(entry.polishedTranscript == "Hello World.")
        #expect(appState.showingResultPanel == true)
        #expect(appState.statusMessage == "")
        #expect(appState.isProcessing == false)
        #expect(appState.processingError == nil)
        #expect(transcriber.initializeCallCount == 1)
        #expect(transcriber.transcribeCallCount == 1)
        #expect(polisher.polishCallCount == 1)
    }

    // MARK: - Test 5: Polisher Error

    @Test("Polisher error sets processingError and shows panel")
    func polishError() async {
        let appState = AppState()
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let glossaryStore = GlossaryStore(baseDirectoryOverride: tempDir)
        let historyStore = HistoryStore(baseDirectoryOverride: tempDir)

        let audioRecorder = FakeAudioRecorder()
        let transcriber = FakeTranscriber()
        let polisher = FakePolisher()
        polisher.polishError = TestError.polishingFailed

        let coordinator = createCoordinator(
            audioRecorder: audioRecorder,
            transcriber: transcriber,
            polisher: polisher,
            appState: appState,
            glossaryStore: glossaryStore,
            historyStore: historyStore
        )

        await coordinator.stopRecordingAndTranscribe()

        #expect(appState.processingError != nil)
        #expect(appState.isProcessing == false)
        #expect(appState.showingResultPanel == true)
        // History should not have an entry if polishing failed
        #expect(historyStore.entries.count == 0)
    }

    // MARK: - Test 6: Transcribe Error

    @Test("Transcribe error sets processingError and shows panel")
    func transcribeError() async {
        let appState = AppState()
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let glossaryStore = GlossaryStore(baseDirectoryOverride: tempDir)
        let historyStore = HistoryStore(baseDirectoryOverride: tempDir)

        let audioRecorder = FakeAudioRecorder()
        let transcriber = FakeTranscriber()
        transcriber.transcribeError = TestError.transcriptionFailed

        let polisher = FakePolisher()

        let coordinator = createCoordinator(
            audioRecorder: audioRecorder,
            transcriber: transcriber,
            polisher: polisher,
            appState: appState,
            glossaryStore: glossaryStore,
            historyStore: historyStore
        )

        await coordinator.stopRecordingAndTranscribe()

        #expect(appState.processingError != nil)
        #expect(appState.isProcessing == false)
        #expect(appState.showingResultPanel == true)
        // Polisher should not have been called if transcribe fails
        #expect(polisher.polishCallCount == 0)
        // History should not have an entry if transcription failed
        #expect(historyStore.entries.count == 0)
    }

    // MARK: - Test 7: Cancellation During Transcription

    @Test("Cancellation during transcription hides panel exactly once")
    func cancellationDuringTranscription() async {
        let appState = AppState()
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let glossaryStore = GlossaryStore(baseDirectoryOverride: tempDir)
        let historyStore = HistoryStore(baseDirectoryOverride: tempDir)

        let audioRecorder = FakeAudioRecorder()
        let transcriber = FakeTranscriber()
        // Add a delay to transcribe so we can cancel during it
        transcriber.initializeDelayNanoseconds = 0

        let polisher = FakePolisher()

        var hideResultPanelCallCount = 0
        let coordinator = createCoordinator(
            audioRecorder: audioRecorder,
            transcriber: transcriber,
            polisher: polisher,
            appState: appState,
            glossaryStore: glossaryStore,
            historyStore: historyStore,
            onHideResultPanel: {
                hideResultPanelCallCount += 1
            }
        )

        // Wrap transcriber to add delay
        class DelayedTranscriber: Transcribing, @unchecked Sendable {
            let wrapped: FakeTranscriber
            init(_ wrapped: FakeTranscriber) { self.wrapped = wrapped }
            func initialize(onProgress: (@Sendable (String) -> Void)?) async throws {
                try await wrapped.initialize(onProgress: onProgress)
            }
            func transcribe(_ samples: [Float]) async throws -> String {
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 second delay
                return try await wrapped.transcribe(samples)
            }
        }

        let delayedTranscriber = DelayedTranscriber(transcriber)
        let coordinatorWithDelay = createCoordinator(
            audioRecorder: audioRecorder,
            transcriber: delayedTranscriber,
            polisher: polisher,
            appState: appState,
            glossaryStore: glossaryStore,
            historyStore: historyStore,
            onHideResultPanel: {
                hideResultPanelCallCount += 1
            }
        )

        // Start the processing task with a delay in transcribe
        let task = Task {
            await coordinatorWithDelay.stopRecordingAndTranscribe()
        }

        // Give it time to reach transcribe
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Cancel the task
        task.cancel()

        // Wait for task completion
        await task.value

        // Assertions
        #expect(hideResultPanelCallCount == 1)
        #expect(appState.isRecording == false)
        #expect(appState.isProcessing == false)
        #expect(appState.showingResultPanel == false)
    }

    // MARK: - Test 8: Recording State After Stop

    @Test("isRecording flag is cleared after stopRecordingAndTranscribe")
    func recordingStateCleared() async {
        let appState = AppState()
        appState.isRecording = true // Simulate active recording

        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let glossaryStore = GlossaryStore(baseDirectoryOverride: tempDir)
        let historyStore = HistoryStore(baseDirectoryOverride: tempDir)

        let audioRecorder = FakeAudioRecorder()
        let transcriber = FakeTranscriber()
        let polisher = FakePolisher()

        let coordinator = createCoordinator(
            audioRecorder: audioRecorder,
            transcriber: transcriber,
            polisher: polisher,
            appState: appState,
            glossaryStore: glossaryStore,
            historyStore: historyStore
        )

        await coordinator.stopRecordingAndTranscribe()

        #expect(appState.isRecording == false)
    }

    // MARK: - Test 9: Status Messages Cleared

    @Test("Status messages are cleared in defer block")
    func statusMessagesCleared() async {
        let appState = AppState()
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let glossaryStore = GlossaryStore(baseDirectoryOverride: tempDir)
        let historyStore = HistoryStore(baseDirectoryOverride: tempDir)

        let audioRecorder = FakeAudioRecorder()
        let transcriber = FakeTranscriber()
        let polisher = FakePolisher()

        let coordinator = createCoordinator(
            audioRecorder: audioRecorder,
            transcriber: transcriber,
            polisher: polisher,
            appState: appState,
            glossaryStore: glossaryStore,
            historyStore: historyStore
        )

        // Set an initial status message
        appState.statusMessage = "Processing..."

        await coordinator.stopRecordingAndTranscribe()

        // Status message should be cleared
        #expect(appState.statusMessage == "")
    }

    // MARK: - Test 10: Polisher Receives Correct Glossary

    @Test("Polisher is called with glossary entries")
    func polisherReceivesGlossary() async {
        let appState = AppState()
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let glossaryStore = GlossaryStore(baseDirectoryOverride: tempDir)
        let historyStore = HistoryStore(baseDirectoryOverride: tempDir)

        // Add a glossary entry
        let entry = GlossaryEntry(canonical: "CloudNative", variants: ["cloud native", "cloud-native"])
        try? glossaryStore.add(entry)

        let audioRecorder = FakeAudioRecorder()
        let transcriber = FakeTranscriber()
        let polisher = FakePolisher()

        let coordinator = createCoordinator(
            audioRecorder: audioRecorder,
            transcriber: transcriber,
            polisher: polisher,
            appState: appState,
            glossaryStore: glossaryStore,
            historyStore: historyStore
        )

        await coordinator.stopRecordingAndTranscribe()

        // Polisher should have been called at least once
        #expect(polisher.polishCallCount >= 1)
        #expect(historyStore.entries.count == 1)
    }

    // MARK: - Test 11: Audio Samples Stored in History

    @Test("Audio samples are stored with history entry")
    func audioSamplesStored() async {
        let appState = AppState()
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let glossaryStore = GlossaryStore(baseDirectoryOverride: tempDir)
        let historyStore = HistoryStore(baseDirectoryOverride: tempDir)

        let expectedSamples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        let audioRecorder = FakeAudioRecorder()
        audioRecorder.stopRecordingResult = expectedSamples

        let transcriber = FakeTranscriber()
        let polisher = FakePolisher()

        let coordinator = createCoordinator(
            audioRecorder: audioRecorder,
            transcriber: transcriber,
            polisher: polisher,
            appState: appState,
            glossaryStore: glossaryStore,
            historyStore: historyStore
        )

        await coordinator.stopRecordingAndTranscribe()

        #expect(historyStore.entries.count == 1)
        let entry = historyStore.entries[0]
        // Audio should be saved (we can't easily compare the exact samples,
        // but we can verify the entry has an audio file)
        #expect(entry.audioFileName != nil)
    }

    // MARK: - Test: Preload Model

    @Test("preloadModel initializes transcriber and clears isModelLoading")
    func preloadModelSucceeds() async {
        let appState = AppState()
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let glossaryStore = GlossaryStore(baseDirectoryOverride: tempDir)
        let historyStore = HistoryStore(baseDirectoryOverride: tempDir)

        let audioRecorder = FakeAudioRecorder()
        let transcriber = FakeTranscriber()
        let polisher = FakePolisher()

        let coordinator = createCoordinator(
            audioRecorder: audioRecorder,
            transcriber: transcriber,
            polisher: polisher,
            appState: appState,
            glossaryStore: glossaryStore,
            historyStore: historyStore
        )

        #expect(appState.isModelLoading == true)

        await coordinator.preloadModel()

        #expect(transcriber.initializeCallCount == 1)
        #expect(appState.isModelLoading == false)
        #expect(appState.modelLoadStatus == "")
    }

    @Test("preloadModel clears isModelLoading even when initialize fails, allowing lazy retry")
    func preloadModelFailureStillClearsLoadingFlag() async {
        let appState = AppState()
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let glossaryStore = GlossaryStore(baseDirectoryOverride: tempDir)
        let historyStore = HistoryStore(baseDirectoryOverride: tempDir)

        let audioRecorder = FakeAudioRecorder()
        let transcriber = FakeTranscriber()
        transcriber.initializeError = TestError.unknown
        let polisher = FakePolisher()

        let coordinator = createCoordinator(
            audioRecorder: audioRecorder,
            transcriber: transcriber,
            polisher: polisher,
            appState: appState,
            glossaryStore: glossaryStore,
            historyStore: historyStore
        )

        await coordinator.preloadModel()

        #expect(appState.isModelLoading == false)
    }

    // MARK: - Test: startRecording Gated on Model Loading

    @Test("startRecording is a no-op while the model is still loading")
    func startRecordingBlockedWhileModelLoading() async {
        let appState = AppState()
        #expect(appState.isModelLoading == true)

        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let glossaryStore = GlossaryStore(baseDirectoryOverride: tempDir)
        let historyStore = HistoryStore(baseDirectoryOverride: tempDir)

        let audioRecorder = FakeAudioRecorder()
        let transcriber = FakeTranscriber()
        let polisher = FakePolisher()

        let coordinator = createCoordinator(
            audioRecorder: audioRecorder,
            transcriber: transcriber,
            polisher: polisher,
            appState: appState,
            glossaryStore: glossaryStore,
            historyStore: historyStore
        )

        await coordinator.startRecording()

        #expect(audioRecorder.startRecordingCallCount == 0)
        #expect(appState.isRecording == false)
    }

    // Note: the "model finished loading" path of startRecording() also calls
    // hasMicrophoneAccess(), which hits the real AVFoundation TCC prompt — not safe to
    // exercise in a unit test, so only the blocked (isModelLoading == true) path is covered
    // here.

    @Test("stopRecordingSync is a no-op if recording never actually started")
    func stopRecordingSyncNoOpWhenNotRecording() async {
        let appState = AppState()
        appState.isRecording = false // startRecording() no-op'd, e.g. blocked on isModelLoading

        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let glossaryStore = GlossaryStore(baseDirectoryOverride: tempDir)
        let historyStore = HistoryStore(baseDirectoryOverride: tempDir)

        let audioRecorder = FakeAudioRecorder()
        let transcriber = FakeTranscriber()
        let polisher = FakePolisher()

        let coordinator = createCoordinator(
            audioRecorder: audioRecorder,
            transcriber: transcriber,
            polisher: polisher,
            appState: appState,
            glossaryStore: glossaryStore,
            historyStore: historyStore
        )

        coordinator.stopRecordingSync()
        await coordinator.processingTask?.value

        #expect(audioRecorder.stopRecordingCallCount == 0)
        #expect(appState.processingError == nil)
        #expect(appState.showingResultPanel == false)
    }

    // MARK: - TranscriptionPipeline Tests

    @Test("TranscriptionPipeline composes transcribe, vocab match, and polish")
    func transcriptionPipeline_ComposesThreeSteps() async throws {
        let audioSamples: [Float] = [0.1, 0.2, 0.3]

        let transcriber = FakeTranscriber()
        transcriber.transcribeResult = "hello world"

        let polisher = FakePolisher()
        polisher.polishResult = "Hello World."

        let glossaryEntry = GlossaryEntry(canonical: "hello", variants: ["helo", "hallo"])
        let glossary = [glossaryEntry]

        let result = try await TranscriptionPipeline.run(
            audioSamples: audioSamples,
            transcriber: transcriber,
            polisher: polisher,
            glossary: glossary
        )

        #expect(transcriber.transcribeCallCount == 1)
        #expect(polisher.polishCallCount == 1)
        #expect(result.rawTranscript == "hello world")
        #expect(result.polishedTranscript == "Hello World.")
    }

    @Test("TranscriptionPipeline propagates transcriber error")
    func transcriptionPipeline_PropagatesTranscriberError() async throws {
        let audioSamples: [Float] = [0.1, 0.2, 0.3]

        let transcriber = FakeTranscriber()
        transcriber.transcribeError = TestError.transcriptionFailed

        let polisher = FakePolisher()
        let glossary: [GlossaryEntry] = []

        do {
            try await TranscriptionPipeline.run(
                audioSamples: audioSamples,
                transcriber: transcriber,
                polisher: polisher,
                glossary: glossary
            )
            #expect(Bool(false), "Should have thrown transcriptionFailed")
        } catch let error as TestError {
            #expect(error == .transcriptionFailed)
        }
    }

    @Test("TranscriptionPipeline propagates polisher error")
    func transcriptionPipeline_PropagatesPolisherError() async throws {
        let audioSamples: [Float] = [0.1, 0.2, 0.3]

        let transcriber = FakeTranscriber()
        transcriber.transcribeResult = "hello world"

        let polisher = FakePolisher()
        polisher.polishError = TestError.polishingFailed

        let glossary: [GlossaryEntry] = []

        do {
            try await TranscriptionPipeline.run(
                audioSamples: audioSamples,
                transcriber: transcriber,
                polisher: polisher,
                glossary: glossary
            )
            #expect(Bool(false), "Should have thrown polishingFailed")
        } catch let error as TestError {
            #expect(error == .polishingFailed)
        }
    }
}
