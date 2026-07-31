import AVFoundation
import Foundation
import Observation
import OSLog

/// A single past recording: its transcripts and (optionally) the saved audio file.
struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let rawTranscript: String
    let polishedTranscript: String
    /// Filename (not full path) inside the entry's folder, if the audio was saved successfully.
    /// New entries use "audio.m4a" (AAC compressed); legacy entries may use "audio.caf" (PCM uncompressed).
    let audioFileName: String?

    init(id: UUID = UUID(), timestamp: Date = Date(), rawTranscript: String, polishedTranscript: String, audioFileName: String?) {
        self.id = id
        self.timestamp = timestamp
        self.rawTranscript = rawTranscript
        self.polishedTranscript = polishedTranscript
        self.audioFileName = audioFileName
    }
}

/// Minimal metadata stored alongside transcript files in each recording folder.
private struct RecordingMetadata: Codable {
    let id: UUID
    let timestamp: Date
}

/// Persists a rolling history of transcriptions and their source audio to
/// `~/Library/Application Support/VoiceType/`.
@MainActor
@Observable
final class HistoryStore {
    @ObservationIgnored private let fileManager = FileManager.default
    @ObservationIgnored private let logger = OSLog(subsystem: "com.voicetype.history", category: "HistoryStore")
    @ObservationIgnored private let maxEntries = 100
    @ObservationIgnored private let baseDirectoryOverride: URL?

    var entries: [HistoryEntry] = []

    var baseDir: URL {
        if let override = baseDirectoryOverride {
            return override
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("VoiceType", isDirectory: true)
    }

    var recordingsDir: URL {
        baseDir.appendingPathComponent("Recordings", isDirectory: true)
    }

    init(baseDirectoryOverride: URL? = nil) {
        self.baseDirectoryOverride = baseDirectoryOverride
        load()
    }

    func load() {
        guard fileManager.fileExists(atPath: recordingsDir.path) else { return }

        var loadedEntries: [HistoryEntry] = []

        do {
            let contents = try fileManager.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: nil)

            for item in contents {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else {
                    // Skip non-directories (e.g., leftover flat .caf files from old format)
                    continue
                }

                // Use folder name as authoritative entry ID; skip if not a valid UUID
                let folderName = item.lastPathComponent
                guard let folderId = UUID(uuidString: folderName) else {
                    os_log("Skipping non-UUID folder: %@", log: logger, type: .debug, folderName)
                    continue
                }

                let metadataURL = item.appendingPathComponent("metadata.json")
                let rawTranscriptURL = item.appendingPathComponent("raw.txt")
                let polishedTranscriptURL = item.appendingPathComponent("polished.txt")

                do {
                    let metadataData = try Data(contentsOf: metadataURL)
                    let decoder = JSONDecoder()
                    let metadata = try decoder.decode(RecordingMetadata.self, from: metadataData)

                    let rawTranscript = try String(contentsOf: rawTranscriptURL, encoding: .utf8)
                    let polishedTranscript = try String(contentsOf: polishedTranscriptURL, encoding: .utf8)

                    // Check for m4a first (new format), then fall back to caf (legacy format)
                    let m4aURL = item.appendingPathComponent("audio.m4a")
                    let cafURL = item.appendingPathComponent("audio.caf")
                    let audioFileName: String?
                    if fileManager.fileExists(atPath: m4aURL.path) {
                        audioFileName = "audio.m4a"
                    } else if fileManager.fileExists(atPath: cafURL.path) {
                        audioFileName = "audio.caf"
                    } else {
                        audioFileName = nil
                    }

                    // Use folder's UUID, not metadata.id, as the authoritative entry ID
                    let entry = HistoryEntry(
                        id: folderId,
                        timestamp: metadata.timestamp,
                        rawTranscript: rawTranscript,
                        polishedTranscript: polishedTranscript,
                        audioFileName: audioFileName
                    )
                    loadedEntries.append(entry)
                } catch {
                    os_log("Failed to load entry from %@: %@", log: logger, type: .debug, folderName, error.localizedDescription)
                    // Skip this folder and continue
                }
            }

            // Sort by timestamp descending, with UUID string as tie-breaker for consistent ordering
            entries = loadedEntries.sorted { ($0.timestamp, $0.id.uuidString) > ($1.timestamp, $1.id.uuidString) }
            os_log("Loaded %d history entries", log: logger, type: .info, entries.count)
        } catch {
            os_log("Failed to load history: %@", log: logger, type: .error, error.localizedDescription)
        }
    }

    /// Save a completed transcription (and its source audio) into history.
    /// Pruning of the oldest entries beyond `maxEntries` happens here, deleting their folders too.
    @discardableResult
    func addEntry(rawTranscript: String, polishedTranscript: String, audioSamples: [Float], sampleRate: Double) -> HistoryEntry {
        let id = UUID()
        let now = Date()
        var audioFileName: String?

        let entryFolder = recordingsDir.appendingPathComponent(id.uuidString, isDirectory: true)

        do {
            try fileManager.createDirectory(at: entryFolder, withIntermediateDirectories: true)

            // Write audio if samples provided. Audio failures are logged but don't prevent transcript persistence.
            if !audioSamples.isEmpty {
                do {
                    let audioURL = entryFolder.appendingPathComponent("audio.m4a")
                    try Self.writeAudio(samples: audioSamples, sampleRate: sampleRate, to: audioURL)
                    audioFileName = "audio.m4a"
                } catch {
                    os_log("Failed to save recording audio: %@", log: logger, type: .debug, error.localizedDescription)
                }
            }

            // Write raw transcript
            let rawURL = entryFolder.appendingPathComponent("raw.txt")
            try rawTranscript.write(to: rawURL, atomically: true, encoding: .utf8)

            // Write polished transcript
            let polishedURL = entryFolder.appendingPathComponent("polished.txt")
            try polishedTranscript.write(to: polishedURL, atomically: true, encoding: .utf8)

            // Write metadata with atomic write
            let metadata = RecordingMetadata(id: id, timestamp: now)
            let metadataURL = entryFolder.appendingPathComponent("metadata.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let metadataData = try encoder.encode(metadata)
            try metadataData.write(to: metadataURL, options: .atomic)
        } catch {
            os_log("Failed to save entry: %@", log: logger, type: .error, error.localizedDescription)
            // Clean up partial folder on transcript/metadata failure to prevent orphaned entries
            try? fileManager.removeItem(at: entryFolder)
        }

        let entry = HistoryEntry(
            id: id,
            timestamp: now,
            rawTranscript: rawTranscript,
            polishedTranscript: polishedTranscript,
            audioFileName: audioFileName
        )
        entries.insert(entry, at: 0)

        if entries.count > maxEntries {
            for stale in entries[maxEntries...] {
                deleteFolder(for: stale)
            }
            entries = Array(entries.prefix(maxEntries))
        }

        return entry
    }

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        deleteFolder(for: entry)
    }

    func audioURL(for entry: HistoryEntry) -> URL? {
        guard let audioFileName = entry.audioFileName else { return nil }
        let url = recordingsDir.appendingPathComponent(entry.id.uuidString).appendingPathComponent(audioFileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func deleteFolder(for entry: HistoryEntry) {
        let folderURL = recordingsDir.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        try? fileManager.removeItem(at: folderURL)
    }

    private static func writeAudio(samples: [Float], sampleRate: Double, to url: URL) throws {
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000
        ]
        let file = try AVAudioFile(forWriting: url, settings: outputSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw HistoryStoreError.audioFormatUnavailable
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData?[0].update(from: ptr.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }
}

enum HistoryStoreError: LocalizedError {
    case audioFormatUnavailable

    var errorDescription: String? {
        switch self {
        case .audioFormatUnavailable:
            return "Could not create audio format for saving recording"
        }
    }
}
