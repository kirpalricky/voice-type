import AVFoundation
import Foundation
import Observation
import OSLog

/// A single past recording: its transcripts and (optionally) the saved audio file.
struct HistoryEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let rawTranscript: String
    let polishedTranscript: String
    /// Filename (not full path) inside the entry's folder, if the audio was saved successfully.
    /// New entries use "audio.m4a" (AAC compressed); legacy entries may use "audio.caf" (PCM uncompressed).
    let audioFileName: String?
    /// The on-disk URL of the folder containing this entry's files (transcripts, audio, metadata).
    /// This is the authoritative location; the folder may be named anything (not necessarily a UUID).
    let folderURL: URL
    /// Lowercased `rawTranscript + polishedTranscript`, precomputed once so search filtering doesn't
    /// re-run ICU case folding on the full transcript text on every keystroke.
    let searchHaystack: String

    /// Cheap nil-check, not persisted — kept as a computed property (not stored) so a future
    /// `Codable` index cache (BACKLOG Stage 4) can't decode a stale value independent of `audioFileName`.
    var hasAudio: Bool { audioFileName != nil }

    init(id: UUID = UUID(), timestamp: Date = Date(), rawTranscript: String, polishedTranscript: String, audioFileName: String?, folderURL: URL) {
        self.id = id
        self.timestamp = timestamp
        self.rawTranscript = rawTranscript
        self.polishedTranscript = polishedTranscript
        self.audioFileName = audioFileName
        self.folderURL = folderURL
        self.searchHaystack = (rawTranscript + " " + polishedTranscript).lowercased()
    }
}

extension HistoryEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case rawTranscript
        case polishedTranscript
        case audioFileName
        case folderURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.rawTranscript = try container.decode(String.self, forKey: .rawTranscript)
        self.polishedTranscript = try container.decode(String.self, forKey: .polishedTranscript)
        self.audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
        self.folderURL = try container.decode(URL.self, forKey: .folderURL)
        self.searchHaystack = (self.rawTranscript + " " + self.polishedTranscript).lowercased()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(rawTranscript, forKey: .rawTranscript)
        try container.encode(polishedTranscript, forKey: .polishedTranscript)
        try container.encodeIfPresent(audioFileName, forKey: .audioFileName)
        try container.encode(folderURL, forKey: .folderURL)
    }
}

/// Minimal metadata stored alongside transcript files in each recording folder.
private struct RecordingMetadata: Codable {
    let id: UUID
    let timestamp: Date
}

/// Envelope structure for the on-disk index cache, including both the cached entries
/// and the set of folder names that were observed on disk during the scan that created this index.
struct HistoryIndex: Codable {
    static let currentVersion = 1

    let version: Int
    let folderNames: [String]
    let entries: [HistoryEntry]
}

/// Persists a rolling history of transcriptions and their source audio to
/// `~/Library/Application Support/Yapboard/`.
@MainActor
@Observable
final class HistoryStore {
    @ObservationIgnored private let fileManager = FileManager.default
    @ObservationIgnored private let logger = OSLog(subsystem: "com.yapboard.history", category: "HistoryStore")
    @ObservationIgnored private let maxEntries: Int
    @ObservationIgnored private let baseDirectoryOverride: URL?
    @ObservationIgnored private var pendingLoadTask: Task<Void, Never>?

    var entries: [HistoryEntry] = []

    var baseDir: URL {
        if let override = baseDirectoryOverride {
            return override
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Yapboard", isDirectory: true)
    }

    var recordingsDir: URL {
        baseDir.appendingPathComponent("Recordings", isDirectory: true)
    }

    var indexURL: URL {
        baseDir.appendingPathComponent("index.json")
    }

    init(baseDirectoryOverride: URL? = nil, maxEntriesOverride: Int? = nil) {
        self.baseDirectoryOverride = baseDirectoryOverride
        self.maxEntries = maxEntriesOverride ?? 5000
        load()
    }

    func load() {
        // Try fast path: check if index.json exists and is valid
        if fileManager.fileExists(atPath: indexURL.path) {
            do {
                let indexData = try Data(contentsOf: indexURL)
                let decoder = JSONDecoder()
                let cachedIndex = try decoder.decode(HistoryIndex.self, from: indexData)

                // Check if index version matches current version
                guard cachedIndex.version == HistoryIndex.currentVersion else {
                    // Version mismatch, fall through to fallback
                    kickOffAsyncScan()
                    return
                }

                // Do shallow listing to check if folders match
                guard fileManager.fileExists(atPath: recordingsDir.path) else {
                    // No recordings dir, but we have a cache — this shouldn't happen in normal use
                    // Fall through to fallback
                    kickOffAsyncScan()
                    return
                }

                do {
                    let contents = try fileManager.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: nil)
                    var actualFolderNames: Set<String> = []
                    for item in contents {
                        var isDir: ObjCBool = false
                        if fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                            actualFolderNames.insert(item.lastPathComponent)
                        }
                    }

                    let cachedFolderNames = Set(cachedIndex.folderNames)

                    if actualFolderNames == cachedFolderNames {
                        // Fast path: cache is valid, use it synchronously
                        // Sort defensively before pruning — pruneExcessEntries() deletes by array
                        // position, so an out-of-order cache (e.g. hand-edited index.json) must not
                        // be allowed to cause the wrong folders to be deleted.
                        entries = cachedIndex.entries.sorted { ($0.timestamp, $0.id.uuidString) > ($1.timestamp, $1.id.uuidString) }
                        if pruneExcessEntries() {
                            writeIndex()
                        }
                        os_log("Loaded %d history entries from cache", log: logger, type: .info, entries.count)
                        return
                    }
                } catch {
                    // Failed to list directory, fall through to fallback
                    os_log("Failed to list recordings directory for cache validation: %@", log: logger, type: .debug, error.localizedDescription)
                }
            } catch {
                // Failed to decode index, fall through to fallback
                os_log("Failed to decode index cache: %@", log: logger, type: .debug, error.localizedDescription)
            }
        }

        // Fallback: kick off async scan
        kickOffAsyncScan()
    }

    /// Kick off an async scan of the Recordings directory.
    /// NOTE: This method is not safe to call concurrently from multiple call sites without adding cancellation logic.
    /// Currently safe because only init() calls load(), which calls this. If a future caller (e.g. a "refresh" button)
    /// is added, ensure this method is protected against concurrent invocation or that the previous task is cancelled first.
    private func kickOffAsyncScan() {
        let recordingsDir = self.recordingsDir
        let indexURL = self.indexURL

        pendingLoadTask = Task.detached(priority: .userInitiated) {
            // Before scanning, check if index.json now exists and is valid
            // (it might have been created by addEntry while we were waiting to run)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                do {
                    let indexData = try Data(contentsOf: indexURL)
                    let decoder = JSONDecoder()
                    let cachedIndex = try decoder.decode(HistoryIndex.self, from: indexData)

                    // Check if index version matches current version
                    if cachedIndex.version != HistoryIndex.currentVersion {
                        // Version mismatch, fall through to full scan
                        let logger = OSLog(subsystem: "com.yapboard.history", category: "HistoryStore")
                        os_log("Index version mismatch, forcing full scan", log: logger, type: .debug)
                    } else if FileManager.default.fileExists(atPath: recordingsDir.path) {
                        // Verify folder names match (fast path validation)
                        let contents = try FileManager.default.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: nil)
                        var actualFolderNames: Set<String> = []
                        for item in contents {
                            var isDir: ObjCBool = false
                            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                                actualFolderNames.insert(item.lastPathComponent)
                            }
                        }

                        let cachedFolderNames = Set(cachedIndex.folderNames)

                        if actualFolderNames == cachedFolderNames {
                            // Cache is valid, merge it with entries that may have been added during scan startup
                            await MainActor.run {
                                self.mergeAndPersistScanResults(cachedIndex.entries)
                            }
                            return
                        }
                    }
                } catch {
                    // Index exists but is invalid, fall through to scan
                    let logger = OSLog(subsystem: "com.yapboard.history", category: "HistoryStore")
                    os_log("Failed to validate index cache in async scan: %@", log: logger, type: .debug, error.localizedDescription)
                }
            }

            // Index doesn't exist or is invalid, perform full scan
            let (scanned, observedFolderNames) = Self.scanDirectory(recordingsDir, fileManager: FileManager.default, logger: OSLog(subsystem: "com.yapboard.history", category: "HistoryStore"))
            await MainActor.run {
                self.mergeAndPersistScanResults(scanned, observedFolderNames: observedFolderNames)
            }
        }
    }

    /// Merge scan results into current entries, avoiding data loss and deletion resurrection.
    /// - Keeps self.entries as the base (entries that may have been added via addEntry/delete during the scan)
    /// - Appends any entry from scanned results whose id is not already in self.entries AND whose folderURL still exists on disk
    /// - Re-sorts with the standard comparator
    /// - Writes the merged index to disk
    private func mergeAndPersistScanResults(_ scanned: [HistoryEntry], observedFolderNames: [String]? = nil) {
        var merged = entries
        let existingIds = Set(entries.map { $0.id })

        for entry in scanned {
            if !existingIds.contains(entry.id) {
                // Check that the folder still exists (prevents resurrecting deleted entries)
                if fileManager.fileExists(atPath: entry.folderURL.path) {
                    merged.append(entry)
                }
            }
        }

        // Re-sort with the standard comparator
        merged.sort { ($0.timestamp, $0.id.uuidString) > ($1.timestamp, $1.id.uuidString) }
        entries = merged

        let pruned = pruneExcessEntries()
        if pruned {
            // Pruning deleted folders on disk, so the caller-provided observedFolderNames
            // (captured before pruning) is now stale — force writeIndex to do a fresh listing.
            writeIndex()
        } else {
            writeIndex(observedFolderNames: observedFolderNames)
        }
    }

    nonisolated private static func scanDirectory(_ recordingsDir: URL, fileManager: FileManager, logger: OSLog) -> (entries: [HistoryEntry], folderNames: [String]) {
        var loadedEntries: [HistoryEntry] = []
        var observedFolderNames: [String] = []

        guard fileManager.fileExists(atPath: recordingsDir.path) else { return ([], []) }

        do {
            let contents = try fileManager.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: nil)

            for item in contents {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else {
                    // Skip non-directories (e.g., leftover flat .caf files from old format)
                    continue
                }

                var folderURL = item
                var folderName = item.lastPathComponent

                let metadataURL = folderURL.appendingPathComponent("metadata.json")

                do {
                    let metadataData = try Data(contentsOf: metadataURL)
                    let decoder = JSONDecoder()
                    let metadata = try decoder.decode(RecordingMetadata.self, from: metadataData)

                    // Best-effort, idempotent migration: legacy folders were named exactly after their
                    // entry's UUID. Rename to a sortable "<yyyyMMdd-HHmmss>-<uuid>" form so Finder lists
                    // history chronologically. Skip on any error — this is cosmetic, not required for correctness.
                    if folderName == metadata.id.uuidString {
                        let sortableName = Self.sortableFolderName(timestamp: metadata.timestamp, id: metadata.id)
                        if sortableName != folderName {
                            let renamedURL = recordingsDir.appendingPathComponent(sortableName, isDirectory: true)
                            if !fileManager.fileExists(atPath: renamedURL.path) {
                                do {
                                    try fileManager.moveItem(at: folderURL, to: renamedURL)
                                    folderURL = renamedURL
                                    folderName = sortableName
                                } catch {
                                    os_log("Failed to migrate legacy folder name %@: %@", log: logger, type: .debug, folderName, error.localizedDescription)
                                }
                            }
                        }
                    }

                    let rawTranscriptURL = folderURL.appendingPathComponent("raw.txt")
                    let polishedTranscriptURL = folderURL.appendingPathComponent("polished.txt")

                    let rawTranscript = try String(contentsOf: rawTranscriptURL, encoding: .utf8)
                    let polishedTranscript = try String(contentsOf: polishedTranscriptURL, encoding: .utf8)

                    // Check for m4a first (new format), then fall back to caf (legacy format)
                    let m4aURL = folderURL.appendingPathComponent("audio.m4a")
                    let cafURL = folderURL.appendingPathComponent("audio.caf")
                    let audioFileName: String?
                    if fileManager.fileExists(atPath: m4aURL.path) {
                        audioFileName = "audio.m4a"
                    } else if fileManager.fileExists(atPath: cafURL.path) {
                        audioFileName = "audio.caf"
                    } else {
                        audioFileName = nil
                    }

                    // Use metadata.id as the authoritative entry ID (not the folder name)
                    let entry = HistoryEntry(
                        id: metadata.id,
                        timestamp: metadata.timestamp,
                        rawTranscript: rawTranscript,
                        polishedTranscript: polishedTranscript,
                        audioFileName: audioFileName,
                        folderURL: folderURL
                    )
                    loadedEntries.append(entry)
                } catch {
                    os_log("Failed to load entry from %@: %@", log: logger, type: .debug, folderName, error.localizedDescription)
                    // Skip this folder and continue (but keep the folder name recorded)
                }

                observedFolderNames.append(folderName)
            }

            // Sort by timestamp descending, with UUID string as tie-breaker for consistent ordering
            loadedEntries.sort { ($0.timestamp, $0.id.uuidString) > ($1.timestamp, $1.id.uuidString) }
            os_log("Loaded %d history entries from disk", log: logger, type: .info, loadedEntries.count)
        } catch {
            os_log("Failed to scan directory: %@", log: logger, type: .error, error.localizedDescription)
        }

        return (loadedEntries, observedFolderNames)
    }

    func waitForPendingLoad() async {
        await pendingLoadTask?.value
    }

    /// Save a completed transcription (and its source audio) into history.
    /// Pruning of the oldest entries beyond `maxEntries` happens here (and also in `load()`), deleting their folders too.
    @discardableResult
    func addEntry(rawTranscript: String, polishedTranscript: String, audioSamples: [Float], sampleRate: Double) -> HistoryEntry {
        let id = UUID()
        let now = Date()
        var audioFileName: String?

        let entryFolder = recordingsDir.appendingPathComponent(Self.sortableFolderName(timestamp: now, id: id), isDirectory: true)
        var didPersist = false

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

            didPersist = true
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
            audioFileName: audioFileName,
            folderURL: entryFolder
        )

        guard didPersist else {
            // Folder write failed and was cleaned up — do not add a phantom in-memory
            // entry with no backing folder (it would silently no-op on delete).
            return entry
        }

        entries.insert(entry, at: 0)
        pruneExcessEntries()
        writeIndex()
        return entry
    }

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        deleteFolder(for: entry)
        writeIndex()
    }

    func audioURL(for entry: HistoryEntry) -> URL? {
        guard let audioFileName = entry.audioFileName else { return nil }
        let url = entry.folderURL.appendingPathComponent(audioFileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func deleteFolder(for entry: HistoryEntry) {
        do {
            try fileManager.removeItem(at: entry.folderURL)
        } catch {
            os_log("Failed to delete entry folder %@: %@", log: logger, type: .error, entry.folderURL.path, error.localizedDescription)
        }
    }

    /// Trims `entries` to `maxEntries`, deleting the folders of any pruned entries.
    /// Returns true if any entries were pruned.
    @discardableResult
    private func pruneExcessEntries() -> Bool {
        guard entries.count > maxEntries else { return false }
        for stale in entries[maxEntries...] {
            deleteFolder(for: stale)
        }
        entries = Array(entries.prefix(maxEntries))
        return true
    }

    private func writeIndex(observedFolderNames: [String]? = nil) {
        do {
            // If folder names weren't provided (e.g., called from addEntry or delete), do a fresh listing
            let folderNames: [String]
            if let provided = observedFolderNames {
                folderNames = provided
            } else {
                var names: [String] = []
                if fileManager.fileExists(atPath: recordingsDir.path) {
                    let contents = try? fileManager.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: nil)
                    if let contents = contents {
                        for item in contents {
                            var isDir: ObjCBool = false
                            if fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                                names.append(item.lastPathComponent)
                            }
                        }
                    }
                }
                folderNames = names
            }

            let index = HistoryIndex(version: HistoryIndex.currentVersion, folderNames: folderNames, entries: entries)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let indexData = try encoder.encode(index)
            try indexData.write(to: indexURL, options: .atomic)
        } catch {
            os_log("Failed to write index cache: %@", log: logger, type: .error, error.localizedDescription)
        }
    }

    nonisolated private static func sortableFolderName(timestamp: Date, id: UUID) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: timestamp)
        let datePart = String(format: "%04d%02d%02d-%02d%02d%02d",
                               components.year ?? 0, components.month ?? 0, components.day ?? 0,
                               components.hour ?? 0, components.minute ?? 0, components.second ?? 0)
        return "\(datePart)-\(id.uuidString)"
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
