import Foundation
import Testing
import AVFoundation
@testable import VoiceType

@Suite
@MainActor
struct HistoryStoreTests {
    // MARK: - Helper Methods

    static func createSampleAudio(sampleCount: Int = 1000) -> [Float] {
        return Array(repeating: 0.1, count: sampleCount)
    }

    func createTempDir() -> URL {
        let tempDirPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirPath, withIntermediateDirectories: true)
        return tempDirPath
    }

    // MARK: - Initialization Tests

    @Test
    func init_StartsEmpty() {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)
        #expect(store.entries.count == 0)
    }

    @Test
    func init_BaseDirCreated() {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)
        #expect(FileManager.default.fileExists(atPath: store.baseDir.path))
    }

    // MARK: - addEntry Tests

    @Test
    func addEntry_CreatesEntry() {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)
        let entry = store.addEntry(
            rawTranscript: "hello world",
            polishedTranscript: "Hello World",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )
        #expect(entry.rawTranscript == "hello world")
        #expect(entry.polishedTranscript == "Hello World")
    }

    @Test
    func addEntry_AppendsToEntries() {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)
        let initialCount = store.entries.count
        store.addEntry(
            rawTranscript: "test 1",
            polishedTranscript: "Test 1",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )
        #expect(store.entries.count == initialCount + 1)
    }


    @Test
    func addEntry_SavesAudioFile() {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)
        let entry = store.addEntry(
            rawTranscript: "audio test",
            polishedTranscript: "Audio Test",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )
        #expect(entry.audioFileName != nil)
        #expect(entry.audioFileName?.hasSuffix(".caf") ?? false)

        // Verify file exists
        let audioURL = store.recordingsDir.appendingPathComponent(entry.audioFileName!)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
    }

    @Test
    func addEntry_TimestampIsRecent() {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)
        let beforeTime = Date()
        let entry = store.addEntry(
            rawTranscript: "test",
            polishedTranscript: "Test",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )
        let afterTime = Date()

        #expect(entry.timestamp >= beforeTime)
        #expect(entry.timestamp <= afterTime)
    }

    // MARK: - Pruning Tests

    @Test
    func addEntry_PrunesOldestWhenExceedsMax() async throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)

        // Add maxEntries + 1 entries
        var firstEntryId: UUID?
        for i in 0...100 {
            let entry = store.addEntry(
                rawTranscript: "entry \(i)",
                polishedTranscript: "Entry \(i)",
                audioSamples: Self.createSampleAudio(),
                sampleRate: 48000
            )
            if i == 0 {
                firstEntryId = entry.id
            }
            // Small delay to ensure different timestamps
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        // Should only have 100 entries (oldest was pruned)
        #expect(store.entries.count == 100)
        // First entry should be gone
        #expect(!store.entries.contains { $0.id == firstEntryId })
    }

    @Test
    func addEntry_DeletesAudioOfPrunedEntry() async throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)

        var prunedAudioFileName: String?

        for i in 0...100 {
            let entry = store.addEntry(
                rawTranscript: "entry \(i)",
                polishedTranscript: "Entry \(i)",
                audioSamples: Self.createSampleAudio(),
                sampleRate: 48000
            )
            if i == 0 {
                prunedAudioFileName = entry.audioFileName
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        // The audio file of the first (pruned) entry should be deleted
        if let fileName = prunedAudioFileName {
            let audioURL = store.recordingsDir.appendingPathComponent(fileName)
            #expect(!FileManager.default.fileExists(atPath: audioURL.path))
        }
    }

    @Test
    func addEntry_PreservesRemainingAudioFiles() async throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)

        var savedFileNames: Set<String> = []

        for i in 0...100 {
            let entry = store.addEntry(
                rawTranscript: "entry \(i)",
                polishedTranscript: "Entry \(i)",
                audioSamples: Self.createSampleAudio(),
                sampleRate: 48000
            )
            if i > 0 && i <= 100 {
                if let fileName = entry.audioFileName {
                    savedFileNames.insert(fileName)
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        // All remaining entries' audio files should exist
        for fileName in savedFileNames {
            let audioURL = store.recordingsDir.appendingPathComponent(fileName)
            #expect(FileManager.default.fileExists(atPath: audioURL.path),
                   "Audio file should exist: \(fileName)")
        }
    }

    // MARK: - Delete Tests

    @Test
    func delete_RemovesEntry() {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)
        let entry = store.addEntry(
            rawTranscript: "to delete",
            polishedTranscript: "To Delete",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )
        #expect(store.entries.count == 1)

        store.delete(entry)
        #expect(store.entries.count == 0)
    }

    @Test
    func delete_RemovesAudioFile() {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)
        let entry = store.addEntry(
            rawTranscript: "delete audio",
            polishedTranscript: "Delete Audio",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )
        guard let fileName = entry.audioFileName else {
            #expect(Bool(false), "Audio file should have been created")
            return
        }

        let audioURL = store.recordingsDir.appendingPathComponent(fileName)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))

        store.delete(entry)
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))
    }

    @Test
    func delete_PersistsToFile() {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)
        let entry = store.addEntry(
            rawTranscript: "test",
            polishedTranscript: "Test",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )
        store.delete(entry)

        // Create a new store to verify deletion was persisted
        let newStore = HistoryStore(baseDirectoryOverride: tempDir)
        #expect(newStore.entries.count == 0)
    }

    @Test
    func delete_MultipleEntries() {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)
        let entry1 = store.addEntry(
            rawTranscript: "entry 1",
            polishedTranscript: "Entry 1",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )
        let entry2 = store.addEntry(
            rawTranscript: "entry 2",
            polishedTranscript: "Entry 2",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )
        let entry3 = store.addEntry(
            rawTranscript: "entry 3",
            polishedTranscript: "Entry 3",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )

        #expect(store.entries.count == 3)

        store.delete(entry2)
        #expect(store.entries.count == 2)
        #expect(!store.entries.contains { $0.id == entry2.id })
        #expect(store.entries.contains { $0.id == entry1.id })
        #expect(store.entries.contains { $0.id == entry3.id })
    }

    // MARK: - Load Tests

    @Test
    func load_CorruptedJSON_LeavesEmpty() throws {
        let tempDirLocal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirLocal, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirLocal) }

        // Write corrupt JSON to the history file
        let historyURL = tempDirLocal.appendingPathComponent("history.json")
        try "invalid json {{{".write(to: historyURL, atomically: true, encoding: .utf8)

        // Create a new store - should handle error gracefully and leave entries empty
        let newStore = HistoryStore(baseDirectoryOverride: tempDirLocal)
        #expect(newStore.entries.count == 0)
    }

    @Test
    func load_MissingFile_StartsEmpty() throws {
        let tempDirLocal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirLocal, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirLocal) }

        // Create a new store - should start empty
        let newStore = HistoryStore(baseDirectoryOverride: tempDirLocal)
        #expect(newStore.entries.count == 0)
    }

    // MARK: - audioURL Tests

    @Test
    func audioURL_ReturnsNilWhenNoFileName() {
        let tempDirLocal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirLocal, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirLocal) }

        let store = HistoryStore(baseDirectoryOverride: tempDirLocal)
        let entry = HistoryEntry(
            rawTranscript: "test",
            polishedTranscript: "Test",
            audioFileName: nil
        )
        let url = store.audioURL(for: entry)
        #expect(url == nil)
    }

    @Test
    func audioURL_ReturnsNilWhenFileDoesntExist() {
        let tempDirLocal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirLocal, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirLocal) }

        let store = HistoryStore(baseDirectoryOverride: tempDirLocal)
        let entry = HistoryEntry(
            id: UUID(),
            rawTranscript: "test",
            polishedTranscript: "Test",
            audioFileName: "nonexistent.caf"
        )
        let url = store.audioURL(for: entry)
        #expect(url == nil)
    }

    @Test
    func audioURL_ReturnsURLWhenFileExists() {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)
        let entry = store.addEntry(
            rawTranscript: "audio test",
            polishedTranscript: "Audio Test",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )
        guard let fileName = entry.audioFileName else {
            #expect(Bool(false), "Audio file should have been created")
            return
        }

        let url = store.audioURL(for: entry)
        #expect(url != nil)
        #expect(FileManager.default.fileExists(atPath: url?.path ?? ""))
        #expect(url?.lastPathComponent.hasSuffix(".caf") ?? false)
    }

}
