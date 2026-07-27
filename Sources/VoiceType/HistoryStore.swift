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
    /// Filename (not full path) inside `HistoryStore.recordingsDir`, if the audio was saved successfully.
    let audioFileName: String?

    init(id: UUID = UUID(), timestamp: Date = Date(), rawTranscript: String, polishedTranscript: String, audioFileName: String?) {
        self.id = id
        self.timestamp = timestamp
        self.rawTranscript = rawTranscript
        self.polishedTranscript = polishedTranscript
        self.audioFileName = audioFileName
    }
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

    private var historyURL: URL {
        baseDir.appendingPathComponent("history.json")
    }

    init(baseDirectoryOverride: URL? = nil) {
        self.baseDirectoryOverride = baseDirectoryOverride
        load()
    }

    func load() {
        guard fileManager.fileExists(atPath: historyURL.path) else { return }
        do {
            let data = try Data(contentsOf: historyURL)
            entries = try JSONDecoder().decode([HistoryEntry].self, from: data)
                .sorted { $0.timestamp > $1.timestamp }
            os_log("Loaded %d history entries", log: logger, type: .info, entries.count)
        } catch {
            os_log("Failed to load history: %@", log: logger, type: .error, error.localizedDescription)
        }
    }

    private func save() {
        do {
            try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try data.write(to: historyURL)
        } catch {
            os_log("Failed to save history: %@", log: logger, type: .error, error.localizedDescription)
        }
    }

    /// Save a completed transcription (and its source audio) into history.
    /// Pruning of the oldest entries beyond `maxEntries` happens here, deleting their audio too.
    @discardableResult
    func addEntry(rawTranscript: String, polishedTranscript: String, audioSamples: [Float], sampleRate: Double) -> HistoryEntry {
        let id = UUID()
        var audioFileName: String?

        do {
            try fileManager.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
            let fileName = "\(id.uuidString).caf"
            let url = recordingsDir.appendingPathComponent(fileName)
            try Self.writeAudio(samples: audioSamples, sampleRate: sampleRate, to: url)
            audioFileName = fileName
        } catch {
            os_log("Failed to save recording audio: %@", log: logger, type: .error, error.localizedDescription)
        }

        let entry = HistoryEntry(
            id: id,
            rawTranscript: rawTranscript,
            polishedTranscript: polishedTranscript,
            audioFileName: audioFileName
        )
        entries.insert(entry, at: 0)

        if entries.count > maxEntries {
            for stale in entries[maxEntries...] {
                deleteAudio(for: stale)
            }
            entries = Array(entries.prefix(maxEntries))
        }

        save()
        return entry
    }

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        deleteAudio(for: entry)
        save()
    }

    func audioURL(for entry: HistoryEntry) -> URL? {
        guard let name = entry.audioFileName else { return nil }
        let url = recordingsDir.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func deleteAudio(for entry: HistoryEntry) {
        guard let name = entry.audioFileName else { return }
        try? fileManager.removeItem(at: recordingsDir.appendingPathComponent(name))
    }

    private static func writeAudio(samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw HistoryStoreError.audioFormatUnavailable
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
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
