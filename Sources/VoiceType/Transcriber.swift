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
    /// - Parameter onProgress: called with a human-readable status string as the model downloads/loads,
    ///   on an unspecified queue — hop to the main actor before touching UI state.
    func initialize(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        guard !isInitialized else {
            return
        }

        // `UnifiedAsrManager.loadModels(to:)` only checks that the encoder
        // bundle exists before deciding the cache is complete — an
        // interrupted or partially-corrupted prior download (decoder/joint/
        // vocab/metadata missing) is otherwise silently treated as "already
        // downloaded" and fails later with a file-not-found error. Purge an
        // incomplete cache up front so a real download runs.
        purgeIncompleteModelCache()

        let manager = UnifiedAsrManager(
            configuration: nil,
            config: config,
            encoderPrecision: .int8
        )

        os_log("Loading Parakeet Unified ASR model...", log: self.logger, type: .info)
        onProgress?("Checking speech model…")

        try await manager.loadModels(to: nil, configuration: nil) { progress in
            let percent = Int(progress.fractionCompleted * 100)
            let phaseText: String
            switch progress.phase {
            case .listing:
                phaseText = "Preparing speech model download…"
            case .downloading(let completedFiles, let totalFiles):
                phaseText = "Downloading speech model (\(completedFiles)/\(totalFiles) files)…"
            case .compiling:
                phaseText = "Compiling speech model…"
            }
            os_log("Download progress: %@", log: self.logger, type: .debug, String(describing: progress))
            onProgress?("\(phaseText) \(percent)%")
        }

        self.asrManager = manager
        self.isInitialized = true

        onProgress?("Speech model ready")
        os_log("Parakeet model initialized successfully", log: self.logger, type: .info)
    }

    /// Delete the on-disk Parakeet Unified model cache if it's missing any
    /// required file, so a subsequent `loadModels(to:)` call re-downloads
    /// instead of loading a broken partial cache.
    private func purgeIncompleteModelCache() {
        let modelsBaseDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        let repoPath = modelsBaseDir.appendingPathComponent(Repo.parakeetUnified.folderName)

        guard FileManager.default.fileExists(atPath: repoPath.path) else {
            return
        }

        let names = ModelNames.ParakeetUnified.self
        let requiredFiles = names.requiredModels(variant: "offline").union([
            names.offlineEncoderFile(precision: .int8)
        ])
        let missing = requiredFiles.filter {
            !FileManager.default.fileExists(atPath: repoPath.appendingPathComponent($0).path)
        }

        guard !missing.isEmpty else {
            return
        }

        os_log(
            "Parakeet model cache at %@ is missing %@ — deleting so it re-downloads",
            log: self.logger, type: .error, repoPath.path, missing.joined(separator: ", "))
        try? FileManager.default.removeItem(at: repoPath)
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
            os_log("Transcription complete: %d chars", log: self.logger, type: .info, transcript.count)
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

extension Transcriber: Transcribing {}

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
