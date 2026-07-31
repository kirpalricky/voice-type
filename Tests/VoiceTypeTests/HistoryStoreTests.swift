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
    func addEntry_CreatesPerFolderStructure() {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)
        let entry = store.addEntry(
            rawTranscript: "audio test",
            polishedTranscript: "Audio Test",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )

        let entryFolder = store.recordingsDir.appendingPathComponent(entry.id.uuidString, isDirectory: true)

        // Check that folder exists
        #expect(FileManager.default.fileExists(atPath: entryFolder.path))

        // Check that audio.m4a exists
        let audioURL = entryFolder.appendingPathComponent("audio.m4a")
        #expect(FileManager.default.fileExists(atPath: audioURL.path))

        // Check that raw.txt exists and has correct content
        let rawURL = entryFolder.appendingPathComponent("raw.txt")
        #expect(FileManager.default.fileExists(atPath: rawURL.path))
        let rawContent = try? String(contentsOf: rawURL, encoding: .utf8)
        #expect(rawContent == "audio test")

        // Check that polished.txt exists and has correct content
        let polishedURL = entryFolder.appendingPathComponent("polished.txt")
        #expect(FileManager.default.fileExists(atPath: polishedURL.path))
        let polishedContent = try? String(contentsOf: polishedURL, encoding: .utf8)
        #expect(polishedContent == "Audio Test")

        // Check that metadata.json exists
        let metadataURL = entryFolder.appendingPathComponent("metadata.json")
        #expect(FileManager.default.fileExists(atPath: metadataURL.path))
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
        #expect(entry.audioFileName == "audio.m4a")

        // Verify file exists in the per-folder structure
        let audioURL = store.recordingsDir.appendingPathComponent(entry.id.uuidString).appendingPathComponent("audio.m4a")
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
    }

    @Test
    func addEntry_WithoutAudioSamples() {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)
        let entry = store.addEntry(
            rawTranscript: "no audio",
            polishedTranscript: "No Audio",
            audioSamples: [],
            sampleRate: 48000
        )

        #expect(entry.audioFileName == nil)

        let entryFolder = store.recordingsDir.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        let audioURL = entryFolder.appendingPathComponent("audio.m4a")
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))

        // But other files should exist
        let rawURL = entryFolder.appendingPathComponent("raw.txt")
        #expect(FileManager.default.fileExists(atPath: rawURL.path))
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
    func addEntry_DeletesFolderOfPrunedEntry() async throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)

        var prunedEntryId: UUID?

        for i in 0...100 {
            let entry = store.addEntry(
                rawTranscript: "entry \(i)",
                polishedTranscript: "Entry \(i)",
                audioSamples: Self.createSampleAudio(),
                sampleRate: 48000
            )
            if i == 0 {
                prunedEntryId = entry.id
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        // The folder of the first (pruned) entry should be deleted
        if let entryId = prunedEntryId {
            let folderURL = store.recordingsDir.appendingPathComponent(entryId.uuidString, isDirectory: true)
            #expect(!FileManager.default.fileExists(atPath: folderURL.path))
        }
    }

    @Test
    func addEntry_PreservesRemainingFolders() async throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)

        var savedEntryIds: Set<UUID> = []

        for i in 0...100 {
            let entry = store.addEntry(
                rawTranscript: "entry \(i)",
                polishedTranscript: "Entry \(i)",
                audioSamples: Self.createSampleAudio(),
                sampleRate: 48000
            )
            if i > 0 {
                // Keep all entries except the first (which gets pruned when count > 100)
                savedEntryIds.insert(entry.id)
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        // All remaining entries' folders should exist (100 entries after pruning)
        for entryId in savedEntryIds {
            let folderURL = store.recordingsDir.appendingPathComponent(entryId.uuidString, isDirectory: true)
            #expect(FileManager.default.fileExists(atPath: folderURL.path),
                   "Entry folder should exist: \(entryId.uuidString)")
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
    func delete_RemovesEntireFolder() {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)
        let entry = store.addEntry(
            rawTranscript: "delete audio",
            polishedTranscript: "Delete Audio",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )

        let folderURL = store.recordingsDir.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: folderURL.path))

        store.delete(entry)
        #expect(!FileManager.default.fileExists(atPath: folderURL.path))
    }

    @Test
    func delete_PersistsToFile() async {
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
        await newStore.waitForPendingLoad()
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
    func load_EmptyDir_StartsEmpty() throws {
        let tempDirLocal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirLocal, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirLocal) }

        // Create a new store - should start empty
        let newStore = HistoryStore(baseDirectoryOverride: tempDirLocal)
        #expect(newStore.entries.count == 0)
    }

    @Test
    func load_IgnoresLegacyFlatCAFFiles() async throws {
        let tempDirLocal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirLocal, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirLocal) }

        // Simulate old format: a flat .caf file directly in Recordings dir
        let recordingsDir = tempDirLocal.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let legacyCAFURL = recordingsDir.appendingPathComponent("old-uuid-1234.caf")
        try "fake audio data".write(to: legacyCAFURL, atomically: true, encoding: .utf8)

        // Create a new store - should ignore the flat .caf file and load empty
        let newStore = HistoryStore(baseDirectoryOverride: tempDirLocal)
        await newStore.waitForPendingLoad()
        #expect(newStore.entries.count == 0)
        // Flat file should still exist (not deleted)
        #expect(FileManager.default.fileExists(atPath: legacyCAFURL.path))
    }

    @Test
    func load_ReconstructsEntriesFromDisk() async throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Add entries with the first store
        let store1 = HistoryStore(baseDirectoryOverride: tempDir)
        let entry1 = store1.addEntry(
            rawTranscript: "first raw",
            polishedTranscript: "First Polished",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )
        // Small delay to ensure different timestamps
        try? await Task.sleep(nanoseconds: 1_000_000)
        let entry2 = store1.addEntry(
            rawTranscript: "second raw",
            polishedTranscript: "Second Polished",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )

        // Delete the index to force fallback scan (test genuinely reconstructs from disk)
        try? FileManager.default.removeItem(at: store1.indexURL)

        // Create a fresh store pointing at the same directory
        let store2 = HistoryStore(baseDirectoryOverride: tempDir)
        await store2.waitForPendingLoad()

        // Should load both entries
        #expect(store2.entries.count == 2)

        // Entries should be in reverse order (newest first)
        #expect(store2.entries[0].id == entry2.id)
        #expect(store2.entries[1].id == entry1.id)

        // Content should be preserved
        #expect(store2.entries[0].rawTranscript == "second raw")
        #expect(store2.entries[0].polishedTranscript == "Second Polished")
        #expect(store2.entries[1].rawTranscript == "first raw")
        #expect(store2.entries[1].polishedTranscript == "First Polished")
    }

    @Test
    func load_CorruptedFolder_SkipsAndContinues() async throws {
        let tempDirLocal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirLocal, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirLocal) }

        // Create one valid entry
        let store = HistoryStore(baseDirectoryOverride: tempDirLocal)
        let validEntry = store.addEntry(
            rawTranscript: "valid",
            polishedTranscript: "Valid",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )

        // Create a corrupted folder (missing metadata.json)
        let recordingsDir = tempDirLocal.appendingPathComponent("Recordings", isDirectory: true)
        let corruptedFolder = recordingsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: corruptedFolder, withIntermediateDirectories: true)
        let rawURL = corruptedFolder.appendingPathComponent("raw.txt")
        try "raw text".write(to: rawURL, atomically: true, encoding: .utf8)

        // Load should skip corrupted folder and still load the valid one
        let newStore = HistoryStore(baseDirectoryOverride: tempDirLocal)
        await newStore.waitForPendingLoad()
        #expect(newStore.entries.count == 1)
        #expect(newStore.entries[0].id == validEntry.id)
    }

    // MARK: - audioURL Tests

    @Test
    func audioURL_ReturnsNilWhenNoFileName() {
        let tempDirLocal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirLocal, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirLocal) }

        let store = HistoryStore(baseDirectoryOverride: tempDirLocal)
        let folderURL = store.recordingsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let entry = HistoryEntry(
            rawTranscript: "test",
            polishedTranscript: "Test",
            audioFileName: nil,
            folderURL: folderURL
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
        let folderURL = store.recordingsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let entry = HistoryEntry(
            id: UUID(),
            rawTranscript: "test",
            polishedTranscript: "Test",
            audioFileName: "audio.caf",
            folderURL: folderURL
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
        guard entry.audioFileName != nil else {
            #expect(Bool(false), "Audio file should have been created")
            return
        }

        let url = store.audioURL(for: entry)
        #expect(url != nil)
        #expect(FileManager.default.fileExists(atPath: url?.path ?? ""))
        #expect(url?.lastPathComponent == "audio.m4a")
    }

    // MARK: - Sub-Second Precision & Tie-Breaking Tests

    @Test
    func load_SubSecondFidelity_NoDelay() async {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Add two entries with NO delay between them
        let store1 = HistoryStore(baseDirectoryOverride: tempDir)
        let entry1 = store1.addEntry(
            rawTranscript: "first",
            polishedTranscript: "First",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )
        let entry2 = store1.addEntry(
            rawTranscript: "second",
            polishedTranscript: "Second",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )

        // Delete the index to force fallback scan (test genuinely reconstructs from disk)
        try? FileManager.default.removeItem(at: store1.indexURL)

        // Reload and verify order is preserved and timestamps have sub-second precision
        let store2 = HistoryStore(baseDirectoryOverride: tempDir)
        await store2.waitForPendingLoad()
        #expect(store2.entries.count == 2)
        #expect(store2.entries[0].id == entry2.id, "Newest entry should be first after reload")
        #expect(store2.entries[1].id == entry1.id, "Older entry should be second after reload")

        // Verify timestamps have sub-second fidelity (within 1ms)
        #expect(abs(store2.entries[1].timestamp.timeIntervalSince(entry1.timestamp)) < 0.001,
               "Reloaded timestamp should match original within 1ms")
    }

    @Test
    func addEntry_AudioFailurePreservesTranscripts() async {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)

        // Add entry without audio samples (simulates audio write being skipped or failing)
        let entry = store.addEntry(
            rawTranscript: "audio not saved",
            polishedTranscript: "Audio Not Saved",
            audioSamples: [],  // Empty audio samples means audio write is skipped
            sampleRate: 48000
        )

        // Entry should be in memory (with no audioFileName)
        #expect(entry.audioFileName == nil)
        #expect(store.entries.count == 1)

        // Delete the index to force fallback scan (test genuinely reconstructs from disk)
        try? FileManager.default.removeItem(at: store.indexURL)

        // Reload and verify transcripts were persisted even without audio
        let store2 = HistoryStore(baseDirectoryOverride: tempDir)
        await store2.waitForPendingLoad()
        #expect(store2.entries.count == 1)
        #expect(store2.entries[0].rawTranscript == "audio not saved")
        #expect(store2.entries[0].polishedTranscript == "Audio Not Saved")
        #expect(store2.entries[0].audioFileName == nil)

        // Verify folder exists with text files but no audio
        let entryFolder = store.recordingsDir.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: entryFolder.path))

        let rawURL = entryFolder.appendingPathComponent("raw.txt")
        let polishedURL = entryFolder.appendingPathComponent("polished.txt")
        let metadataURL = entryFolder.appendingPathComponent("metadata.json")
        let audioURL = entryFolder.appendingPathComponent("audio.m4a")

        #expect(FileManager.default.fileExists(atPath: rawURL.path), "raw.txt should exist")
        #expect(FileManager.default.fileExists(atPath: polishedURL.path), "polished.txt should exist")
        #expect(FileManager.default.fileExists(atPath: metadataURL.path), "metadata.json should exist")
        #expect(!FileManager.default.fileExists(atPath: audioURL.path), "audio.m4a should not exist without audio samples")
    }

    @Test
    func load_RenamedFolder_PreservesMetadataIdUsesNewFolderURL() async {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create an entry
        let store1 = HistoryStore(baseDirectoryOverride: tempDir)
        let originalEntry = store1.addEntry(
            rawTranscript: "rename test",
            polishedTranscript: "Rename Test",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )
        let originalId = originalEntry.id

        // Simulate user renaming folder in Finder: rename it to a different UUID
        let recordingsDir = store1.recordingsDir
        let originalFolder = recordingsDir.appendingPathComponent(originalEntry.id.uuidString, isDirectory: true)
        let newFolderId = UUID()
        let renamedFolder = recordingsDir.appendingPathComponent(newFolderId.uuidString, isDirectory: true)

        try? FileManager.default.moveItem(at: originalFolder, to: renamedFolder)

        // Now load and verify the entry ID comes from metadata.id, not the new folder name
        let store2 = HistoryStore(baseDirectoryOverride: tempDir)
        await store2.waitForPendingLoad()
        #expect(store2.entries.count == 1)
        #expect(store2.entries[0].id == originalId, "Loaded entry ID should match original metadata.id, not new folder name")
        #expect(store2.entries[0].folderURL.lastPathComponent == renamedFolder.lastPathComponent, "folderURL should point to the renamed folder location")
        #expect(store2.entries[0].rawTranscript == "rename test", "Transcript should be preserved")
    }

    @Test
    func addEntry_Exactly100_NoPruning() async throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)

        var entryIds: Set<UUID> = []

        // Add exactly 100 entries (which is maxEntries)
        for i in 0..<100 {
            let entry = store.addEntry(
                rawTranscript: "entry \(i)",
                polishedTranscript: "Entry \(i)",
                audioSamples: Self.createSampleAudio(),
                sampleRate: 48000
            )
            entryIds.insert(entry.id)
            if i < 99 {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        // Should have exactly 100 entries (no pruning yet)
        #expect(store.entries.count == 100)

        // All folders should exist
        for entryId in entryIds {
            let folderURL = store.recordingsDir.appendingPathComponent(entryId.uuidString, isDirectory: true)
            #expect(FileManager.default.fileExists(atPath: folderURL.path),
                   "All 100 entry folders should exist")
        }

        // Delete the index to force fallback scan (test genuinely reconstructs from disk)
        try? FileManager.default.removeItem(at: store.indexURL)

        // Reload to verify all 100 persisted
        let store2 = HistoryStore(baseDirectoryOverride: tempDir)
        await store2.waitForPendingLoad()
        #expect(store2.entries.count == 100)
    }

    @Test
    func load_LegacyCAFFile_IsFoundAndUsable() async throws {
        let tempDirLocal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirLocal, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirLocal) }

        // Create a legacy entry folder manually (simulating an entry saved before AAC conversion)
        let legacyId = UUID()
        let recordingsDir = tempDirLocal.appendingPathComponent("Recordings", isDirectory: true)
        let legacyFolder = recordingsDir.appendingPathComponent(legacyId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)

        // Create metadata.json with a simple structure that matches RecordingMetadata
        // We use a Dictionary since RecordingMetadata is private to HistoryStore
        let metadata: [String: Any] = [
            "id": legacyId.uuidString,
            "timestamp": Date().timeIntervalSinceReferenceDate
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        let metadataURL = legacyFolder.appendingPathComponent("metadata.json")
        try metadataData.write(to: metadataURL)

        // Create raw.txt and polished.txt
        let rawURL = legacyFolder.appendingPathComponent("raw.txt")
        try "legacy raw transcript".write(to: rawURL, atomically: true, encoding: .utf8)
        let polishedURL = legacyFolder.appendingPathComponent("polished.txt")
        try "Legacy Polished Transcript".write(to: polishedURL, atomically: true, encoding: .utf8)

        // Create a legacy audio.caf file (just dummy content for this test)
        let cafURL = legacyFolder.appendingPathComponent("audio.caf")
        try "fake audio data".write(to: cafURL, atomically: true, encoding: .utf8)

        // Load the store and verify the legacy entry is found
        let store = HistoryStore(baseDirectoryOverride: tempDirLocal)
        await store.waitForPendingLoad()
        #expect(store.entries.count == 1)
        let loadedEntry = store.entries[0]

        #expect(loadedEntry.id == legacyId)
        #expect(loadedEntry.rawTranscript == "legacy raw transcript")
        #expect(loadedEntry.polishedTranscript == "Legacy Polished Transcript")
        #expect(loadedEntry.audioFileName == "audio.caf", "Legacy entry should report audio.caf as filename")

        // Verify audioURL correctly returns the legacy .caf file
        let audioURL = store.audioURL(for: loadedEntry)
        #expect(audioURL != nil)
        #expect(audioURL?.lastPathComponent == "audio.caf")
        #expect(FileManager.default.fileExists(atPath: audioURL?.path ?? ""))
    }

    // MARK: - Audio Format & Round-Trip Tests

    @Test
    func addEntry_AudioRoundTrip_VerifiesAACEncoding() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)

        // Generate 48000 samples (3 seconds at 16kHz) with a varying sine wave signal
        let sampleCount = 48000
        let sampleRate: Double = 16000
        let frequency: Float = 440.0  // A4 note
        var audioSamples: [Float] = []
        for i in 0..<sampleCount {
            let phase = Float(i) * frequency / Float(sampleRate) * 2.0 * .pi
            let sample = sin(phase) * 0.3  // 0.3 amplitude to avoid clipping
            audioSamples.append(sample)
        }

        // Add entry with the audio samples
        let entry = store.addEntry(
            rawTranscript: "round trip test",
            polishedTranscript: "Round Trip Test",
            audioSamples: audioSamples,
            sampleRate: sampleRate
        )

        #expect(entry.audioFileName == "audio.m4a")

        // Get the audio URL
        guard let audioURL = store.audioURL(for: entry) else {
            #expect(Bool(false), "Audio URL should exist")
            return
        }

        #expect(FileManager.default.fileExists(atPath: audioURL.path))

        // Reopen the file and verify AAC encoding
        let readFile = try AVAudioFile(forReading: audioURL)

        // Verify the format is AAC
        let formatID = readFile.fileFormat.streamDescription.pointee.mFormatID
        #expect(formatID == kAudioFormatMPEG4AAC, "Audio file should be encoded as AAC (format ID: \(formatID) vs expected: \(kAudioFormatMPEG4AAC))")

        // Verify the file length is reasonable (within tolerance for AAC frame boundaries)
        // AAC frames can add some delay/padding; allow ±5000 frames tolerance
        let fileLength = Int(readFile.length)
        let expectedLength = sampleCount
        let tolerance = 5000
        #expect(fileLength >= expectedLength - tolerance && fileLength <= expectedLength + tolerance,
               "File length (\(fileLength)) should be close to input samples (\(expectedLength)), within ±\(tolerance) tolerance")

        // Verify file size is compressed (much smaller than raw PCM)
        // Raw PCM would be sampleCount * 4 bytes (Float32) = 192,000 bytes
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let fileSize = fileAttributes[.size] as? Int ?? 0
        let rawPCMSize = sampleCount * 4  // Float32 = 4 bytes per sample
        let compressionRatio = Double(fileSize) / Double(rawPCMSize)

        #expect(fileSize > 0, "Audio file should have content")
        #expect(compressionRatio < 0.5, "AAC compression should reduce file to less than 50% of raw PCM (\(fileSize) bytes vs \(rawPCMSize) raw)")
    }

    // MARK: - Index Cache Tests

    @Test
    func indexCache_CreatedAfterAddEntry() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)

        // Initially, no index.json
        #expect(!FileManager.default.fileExists(atPath: store.indexURL.path))

        // Add an entry
        let entry = store.addEntry(
            rawTranscript: "test",
            polishedTranscript: "Test",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )

        // Index file should now exist
        #expect(FileManager.default.fileExists(atPath: store.indexURL.path))

        // Verify the index file contains the entry
        let indexData = try Data(contentsOf: store.indexURL)
        let decoder = JSONDecoder()
        let decodedIndex = try decoder.decode(HistoryIndex.self, from: indexData)
        #expect(decodedIndex.entries.count == 1)
        #expect(decodedIndex.entries[0].id == entry.id)
        #expect(decodedIndex.entries[0].rawTranscript == "test")
    }

    @Test
    func indexCache_UpdatedAfterDelete() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = HistoryStore(baseDirectoryOverride: tempDir)

        // Add two entries
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

        // Delete the first entry
        store.delete(entry1)

        // Verify index file is updated
        let indexData = try Data(contentsOf: store.indexURL)
        let decoder = JSONDecoder()
        let decodedIndex = try decoder.decode(HistoryIndex.self, from: indexData)
        #expect(decodedIndex.entries.count == 1)
        #expect(decodedIndex.entries[0].id == entry2.id)
    }

    @Test
    func indexCache_FastPathSync_MatchingFolders() {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create entries with the first store (writes index)
        let store1 = HistoryStore(baseDirectoryOverride: tempDir)
        let entry1 = store1.addEntry(
            rawTranscript: "first",
            polishedTranscript: "First",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )
        let entry2 = store1.addEntry(
            rawTranscript: "second",
            polishedTranscript: "Second",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )

        // Create a second store — it should load from cache synchronously
        let store2 = HistoryStore(baseDirectoryOverride: tempDir)

        // Entries should be populated immediately (synchronous load)
        #expect(store2.entries.count == 2)
        #expect(store2.entries[0].id == entry2.id)
        #expect(store2.entries[1].id == entry1.id)
    }

    @Test
    func indexCache_FallbackPath_CorruptIndex() async throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create an entry and a valid index
        let store1 = HistoryStore(baseDirectoryOverride: tempDir)
        let entry1 = store1.addEntry(
            rawTranscript: "test",
            polishedTranscript: "Test",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )

        // Corrupt the index file by overwriting with garbage
        let corruptData = "this is not valid json".data(using: .utf8)!
        try corruptData.write(to: store1.indexURL, options: .atomic)

        // Create a second store — should fall back to async scan despite corrupted index
        let store2 = HistoryStore(baseDirectoryOverride: tempDir)
        await store2.waitForPendingLoad()

        // Should still load the entry correctly
        #expect(store2.entries.count == 1)
        #expect(store2.entries[0].id == entry1.id)

        // A new valid index should have been written
        let indexData = try Data(contentsOf: store2.indexURL)
        let decoder = JSONDecoder()
        let decodedIndex = try decoder.decode(HistoryIndex.self, from: indexData)
        #expect(decodedIndex.entries.count == 1)
    }

    @Test
    func indexCache_FastPath_StaleCacheFallsBack() async throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create an entry and a valid index
        let store1 = HistoryStore(baseDirectoryOverride: tempDir)
        let entry1 = store1.addEntry(
            rawTranscript: "first",
            polishedTranscript: "First",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )

        // Manually add a new folder on disk (simulating external addition)
        let recordingsDir = store1.recordingsDir
        let extraFolder = recordingsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: extraFolder, withIntermediateDirectories: true)

        // Add metadata.json with a new ID
        let newId = UUID()
        let metadataURL = extraFolder.appendingPathComponent("metadata.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadata: [String: Any] = [
            "id": newId.uuidString,
            "timestamp": Date().timeIntervalSinceReferenceDate
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        try metadataData.write(to: metadataURL)

        // Add raw.txt and polished.txt
        try "extra raw".write(to: extraFolder.appendingPathComponent("raw.txt"), atomically: true, encoding: .utf8)
        try "Extra Polished".write(to: extraFolder.appendingPathComponent("polished.txt"), atomically: true, encoding: .utf8)

        // Create a second store — cache is now stale (2 folders on disk, 1 in cache)
        // So it should fall back to async scan
        let store2 = HistoryStore(baseDirectoryOverride: tempDir)
        await store2.waitForPendingLoad()

        // Should have loaded both entries
        #expect(store2.entries.count == 2)
    }

    @Test
    func waitForPendingLoad_IsSafeToCallWhenNoPendingLoad() async {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a store — fast path, no pending load
        let store = HistoryStore(baseDirectoryOverride: tempDir)

        // Should be safe to call waitForPendingLoad even though there's no pending task
        await store.waitForPendingLoad()

        #expect(store.entries.count == 0)
    }

    // MARK: - Finding 1: Merge Fix Tests

    @Test
    func asyncScan_MergesWithAddEntryDuringLoad() async throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Add initial entries
        let store1 = HistoryStore(baseDirectoryOverride: tempDir)
        let entry1 = store1.addEntry(
            rawTranscript: "initial entry",
            polishedTranscript: "Initial Entry",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )

        // Delete the index to trigger async fallback scan
        try? FileManager.default.removeItem(at: store1.indexURL)

        // Create a new store that will kick off async scan
        let store2 = HistoryStore(baseDirectoryOverride: tempDir)

        // Immediately add a new entry BEFORE the async scan completes
        let entry2 = store2.addEntry(
            rawTranscript: "added during scan",
            polishedTranscript: "Added During Scan",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )

        // Wait for the async scan to complete
        await store2.waitForPendingLoad()

        // Both entries should be present (merge worked, didn't overwrite with just scanned entries)
        #expect(store2.entries.count == 2, "Both original and newly added entry should be present")
        #expect(store2.entries.contains { $0.id == entry1.id }, "Original entry should be present")
        #expect(store2.entries.contains { $0.id == entry2.id }, "Newly added entry should be present")

        // Newest should be first
        #expect(store2.entries[0].id == entry2.id, "Newly added entry should sort first")
    }

    // MARK: - Finding 2: Corrupt Folder Cache Stickiness Tests

    @Test
    func asyncScan_CorruptFolder_CacheBecomesSticky() async throws {
        let tempDirLocal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirLocal, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirLocal) }

        // Create one valid entry
        let store = HistoryStore(baseDirectoryOverride: tempDirLocal)
        let validEntry = store.addEntry(
            rawTranscript: "valid",
            polishedTranscript: "Valid",
            audioSamples: Self.createSampleAudio(),
            sampleRate: 48000
        )

        // Create a corrupted folder (missing metadata.json) to simulate an unparseable entry
        let recordingsDir = tempDirLocal.appendingPathComponent("Recordings", isDirectory: true)
        let corruptedFolder = recordingsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: corruptedFolder, withIntermediateDirectories: true)
        let rawURL = corruptedFolder.appendingPathComponent("raw.txt")
        try "raw text".write(to: rawURL, atomically: true, encoding: .utf8)

        // Delete index to force rebuild
        try? FileManager.default.removeItem(at: store.indexURL)

        // First load: scan finds valid entry and corrupted folder, creates index with both folder names
        let store2 = HistoryStore(baseDirectoryOverride: tempDirLocal)
        await store2.waitForPendingLoad()
        #expect(store2.entries.count == 1, "Should have loaded only the valid entry")
        #expect(store2.entries[0].id == validEntry.id, "Should load the valid entry")

        // Verify that the rebuilt index includes the corrupted folder name in folderNames
        let indexData = try Data(contentsOf: store2.indexURL)
        let decoder = JSONDecoder()
        let index = try decoder.decode(HistoryIndex.self, from: indexData)
        #expect(index.folderNames.count == 2, "Index should record both folder names (valid and corrupted)")
        #expect(index.entries.count == 1, "Index should only have the valid entry")

        // Second load: cache should now be valid and sticky (no rescan needed)
        let store3 = HistoryStore(baseDirectoryOverride: tempDirLocal)
        // Note: no await, should load synchronously from cache
        #expect(store3.entries.count == 1, "Second load should use cache synchronously")
        #expect(store3.entries[0].id == validEntry.id, "Cached entry should be present")
    }
}
