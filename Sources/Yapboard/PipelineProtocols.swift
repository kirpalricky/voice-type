import Foundation

/// Protocol for audio recording operations
protocol AudioRecording: Sendable {
    func startRecording(onBands: (@Sendable ([Float]) -> Void)?) async throws
    func stopRecording() async throws -> [Float]
}

/// Protocol for speech-to-text transcription operations
protocol Transcribing: Sendable {
    func initialize(onProgress: (@Sendable (String) -> Void)?) async throws
    func transcribe(_ samples: [Float]) async throws -> String
}

/// Protocol for transcript polishing/enhancement operations
protocol Polishing: Sendable {
    func polish(_ text: String, glossary: [String]) async throws -> String
}
