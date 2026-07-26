import FluidAudio
import Foundation
import OSLog

/// Wraps FluidAudio's Parakeet model for speech-to-text transcription
actor Transcriber {
    private let logger = OSLog(subsystem: "com.voicetype.transcriber", category: "Transcriber")

    private var asrManager: UnifiedAsrManager?
    private var isInitialized = false

    nonisolated let config: UnifiedConfig

    init(config: UnifiedConfig = UnifiedConfig()) {
        self.config = config
    }

    /// Initialize and load the Parakeet Unified model
    /// Models are downloaded and cached automatically from HuggingFace
    func initialize() async throws {
        guard !isInitialized else {
            return
        }

        let manager = UnifiedAsrManager(
            configuration: nil,
            config: config,
            encoderPrecision: .int8
        )

        os_log("Loading Parakeet Unified ASR model...", log: self.logger, type: .info)

        try await manager.loadModels(to: nil, configuration: nil) { progress in
            os_log("Download progress: %@", log: self.logger, type: .debug, String(describing: progress))
        }

        self.asrManager = manager
        self.isInitialized = true

        os_log("Parakeet model initialized successfully", log: self.logger, type: .info)
    }

    /// Transcribe audio samples (16 kHz mono Float32)
    /// - Parameter samples: Audio samples at 16 kHz, mono, Float32 format
    /// - Returns: Transcribed text
    func transcribe(_ samples: [Float]) async throws -> String {
        guard isInitialized, let manager = asrManager else {
            throw TranscriberError.notInitialized
        }

        guard !samples.isEmpty else {
            return ""
        }

        os_log("Transcribing %d audio samples", log: self.logger, type: .debug, samples.count)

        do {
            let transcript = try await manager.transcribe(samples)
            os_log("Transcription complete: %@", log: self.logger, type: .info, transcript)
            return transcript
        } catch {
            os_log("Transcription failed: %@", log: self.logger, type: .error, error.localizedDescription)
            throw TranscriberError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Cleanup resources
    func cleanup() async {
        if let manager = asrManager {
            await manager.cleanup()
        }
        isInitialized = false
        asrManager = nil

        os_log("Transcriber cleaned up", log: self.logger, type: .info)
    }
}

enum TranscriberError: LocalizedError {
    case notInitialized
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Transcriber not initialized"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        }
    }
}
