import Foundation
import OSLog

/// Orchestrates reprocessing of a history entry: decode audio, run transcription pipeline, update history.
@MainActor
final class HistoryReprocessor {
    private let historyStore: HistoryStore
    private let appState: AppState
    private let transcriber: Transcribing
    private let polisher: Polishing
    private let glossaryStore: GlossaryStore
    private let logger: OSLog

    init(
        historyStore: HistoryStore,
        appState: AppState,
        transcriber: Transcribing,
        polisher: Polishing,
        glossaryStore: GlossaryStore
    ) {
        self.historyStore = historyStore
        self.appState = appState
        self.transcriber = transcriber
        self.polisher = polisher
        self.glossaryStore = glossaryStore
        self.logger = OSLog(subsystem: "com.yapboard.reprocess", category: "HistoryReprocessor")
    }

    /// Reprocesses a history entry: decodes saved audio and reruns transcription/polishing.
    /// - Parameter entry: The history entry to reprocess (must exist in historyStore)
    /// - Returns: The updated history entry
    /// - Throws: ReprocessError with specific failure modes
    @discardableResult
    func reprocess(_ entry: HistoryEntry) async throws -> HistoryEntry {
        // Check if model is still loading
        guard !appState.isModelLoading else {
            os_log("Reprocess blocked: model still loading", log: self.logger, type: .debug)
            throw ReprocessError.modelBusy
        }

        // Get the audio URL
        guard let audioURL = historyStore.audioURL(for: entry) else {
            os_log("Reprocess failed: no audio for entry %@", log: self.logger, type: .debug, entry.id.uuidString)
            throw ReprocessError.noAudio
        }

        // Decode audio off the main actor
        let audioSamples = try await Task.detached(priority: .userInitiated) {
            try AudioDecoder.decodeTo16kMono(fileURL: audioURL)
        }.value

        // Guard against empty audio
        guard !audioSamples.isEmpty else {
            os_log("Reprocess failed: decoded audio is empty for entry %@", log: self.logger, type: .debug, entry.id.uuidString)
            throw ReprocessError.emptyAudio
        }

        // Hoist glossary entries on main actor before calling pipeline
        let glossaryEntries = glossaryStore.entries

        // Run transcription pipeline
        let pipelineResult = try await TranscriptionPipeline.run(
            audioSamples: audioSamples,
            transcriber: transcriber,
            polisher: polisher,
            glossary: glossaryEntries
        )

        // Check for polish downgrade: if the new polished output is identical to raw,
        // but the original was polished (polished != raw), reject the update to avoid
        // silently downgrading a good transcript.
        if pipelineResult.polishedTranscript == pipelineResult.rawTranscript &&
           entry.polishedTranscript != entry.rawTranscript {
            os_log("Reprocess blocked: polish would downgrade transcript for entry %@", log: self.logger, type: .debug, entry.id.uuidString)
            throw ReprocessError.polishDowngrade
        }

        // Update the entry in history
        let updatedEntry = try historyStore.updateEntry(
            entry,
            rawTranscript: pipelineResult.rawTranscript,
            polishedTranscript: pipelineResult.polishedTranscript
        )

        os_log("Reprocess complete for entry %@: %d chars raw, %d chars polished", log: self.logger, type: .info, entry.id.uuidString, pipelineResult.rawTranscript.count, pipelineResult.polishedTranscript.count)

        return updatedEntry
    }
}

enum ReprocessError: LocalizedError {
    case noAudio
    case emptyAudio
    case modelBusy
    case polishDowngrade

    var errorDescription: String? {
        switch self {
        case .noAudio:
            return "This entry has no saved audio"
        case .emptyAudio:
            return "Audio appears to be empty or corrupted"
        case .modelBusy:
            return "Speech model is still loading, try again shortly"
        case .polishDowngrade:
            return "Reprocessing produced no polished output; entry left unchanged"
        }
    }
}
