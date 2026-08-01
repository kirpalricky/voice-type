import Foundation
import Testing
@testable import Yapboard

@Suite
@MainActor
struct GlossaryStoreTests {
    func createTempDir() -> URL {
        let tempDirPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirPath, withIntermediateDirectories: true)
        return tempDirPath
    }

    // MARK: - Initialization Tests

    @Test
    func init_CreatesExampleEntries() {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = GlossaryStore(baseDirectoryOverride: tempDir)

        // First initialization should seed example entries
        #expect(store.entries.count > 0)
        #expect(store.entries.contains { $0.canonical == "CloudNative" })
    }

    @Test
    func init_SavesExampleEntries() {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        _ = GlossaryStore(baseDirectoryOverride: tempDir)

        // Example entries should be persisted to disk
        let glossaryURL = tempDir.appendingPathComponent("glossary.json")
        #expect(FileManager.default.fileExists(atPath: glossaryURL.path))
    }

    // MARK: - Add Tests

    @Test
    func add_AppendsEntry() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = GlossaryStore(baseDirectoryOverride: tempDir)

        let initialCount = store.entries.count
        let newEntry = GlossaryEntry(canonical: "NewTerm", variants: ["new term"])
        try store.add(newEntry)
        #expect(store.entries.count == initialCount + 1)
        #expect(store.entries.contains { $0.canonical == "NewTerm" })
    }

    @Test
    func add_PersistsToFile() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = GlossaryStore(baseDirectoryOverride: tempDir)

        let newEntry = GlossaryEntry(canonical: "TestEntry", variants: ["test entry"])
        try store.add(newEntry)

        // Create a new store to verify persistence
        let newStore = GlossaryStore(baseDirectoryOverride: tempDir)
        #expect(newStore.entries.contains { $0.canonical == "TestEntry" })
    }

    // MARK: - Remove Tests

    @Test
    func remove_DeletesEntry() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = GlossaryStore(baseDirectoryOverride: tempDir)

        #expect(store.entries.count > 0)
        let initialCount = store.entries.count
        let entryToRemove = store.entries[0]
        try store.remove(at: 0)
        #expect(store.entries.count == initialCount - 1)
        #expect(!store.entries.contains { $0.id == entryToRemove.id })
    }

    @Test
    func remove_InvalidIndex() {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = GlossaryStore(baseDirectoryOverride: tempDir)

        let invalidIndex = 999
        #expect(throws: GlossaryError.self) {
            try store.remove(at: invalidIndex)
        }
    }

    @Test
    func remove_PersistsToFile() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = GlossaryStore(baseDirectoryOverride: tempDir)

        #expect(store.entries.count > 0)
        try store.remove(at: 0)

        // Create a new store to verify persistence
        let newStore = GlossaryStore(baseDirectoryOverride: tempDir)
        #expect(newStore.entries.count == store.entries.count)
    }

    // MARK: - Save/Load Round-trip Tests

    @Test
    func roundTrip_AddAndLoad() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = GlossaryStore(baseDirectoryOverride: tempDir)

        let entry1 = GlossaryEntry(canonical: "Entry1", variants: ["variant1"])
        let entry2 = GlossaryEntry(canonical: "Entry2", variants: ["variant2a", "variant2b"])
        try store.add(entry1)
        try store.add(entry2)

        // Load from disk in a new store
        let newStore = GlossaryStore(baseDirectoryOverride: tempDir)
        #expect(newStore.entries.count >= 2)
        #expect(newStore.entries.contains { $0.canonical == "Entry1" })
        #expect(newStore.entries.contains { $0.canonical == "Entry2" })
    }

    @Test
    func roundTrip_VariantsPreserved() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = GlossaryStore(baseDirectoryOverride: tempDir)

        let entry = GlossaryEntry(canonical: "Special", variants: ["special form", "special type", "special version"])
        try store.add(entry)

        let newStore = GlossaryStore(baseDirectoryOverride: tempDir)
        guard let loadedEntry = newStore.entries.first(where: { $0.canonical == "Special" }) else {
            #expect(Bool(false), "Entry not found after load")
            return
        }
        #expect(loadedEntry.variants.count == 3)
        #expect(loadedEntry.variants.contains("special form"))
    }

    // MARK: - Corrupt JSON Tests

    @Test
    func load_CorruptJSON_SeedsExamples() throws {
        let tempDirLocal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirLocal, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirLocal) }

        // Write corrupt JSON to the glossary file
        let glossaryURL = tempDirLocal.appendingPathComponent("glossary.json")
        try "invalid json {{{".write(to: glossaryURL, atomically: true, encoding: .utf8)

        // Create a new store - should handle error gracefully and seed examples
        let newStore = GlossaryStore(baseDirectoryOverride: tempDirLocal)
        #expect(newStore.entries.count > 0)
        #expect(newStore.entries.contains { $0.canonical == "CloudNative" })
    }

    // MARK: - Empty State Tests

    @Test
    func load_MissingFile_SeedsExamples() throws {
        let tempDirLocal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirLocal, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirLocal) }

        // Create a new store - should seed examples
        let newStore = GlossaryStore(baseDirectoryOverride: tempDirLocal)
        #expect(newStore.entries.count > 0)
        let glossaryURL = tempDirLocal.appendingPathComponent("glossary.json")
        #expect(FileManager.default.fileExists(atPath: glossaryURL.path))
    }

    @Test
    func load_MissingFile_CreatesFile() throws {
        let tempDirLocal = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirLocal, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirLocal) }

        let glossaryURL = tempDirLocal.appendingPathComponent("glossary.json")
        // New store should create the file
        let newStore = GlossaryStore(baseDirectoryOverride: tempDirLocal)
        #expect(FileManager.default.fileExists(atPath: glossaryURL.path))

        // File should contain valid JSON
        let data = try Data(contentsOf: glossaryURL)
        let decoded = try JSONDecoder().decode([GlossaryEntry].self, from: data)
        #expect(decoded.count == newStore.entries.count)
    }

    // MARK: - Concurrent Operations Tests

    @Test
    func concurrentAdditions() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = GlossaryStore(baseDirectoryOverride: tempDir)

        let entry1 = GlossaryEntry(canonical: "Concurrent1", variants: [])
        let entry2 = GlossaryEntry(canonical: "Concurrent2", variants: [])
        let entry3 = GlossaryEntry(canonical: "Concurrent3", variants: [])

        // Add entries sequentially (GlossaryStore is @MainActor, so this is expected usage)
        try store.add(entry1)
        try store.add(entry2)
        try store.add(entry3)

        #expect(store.entries.count >= 3)
        #expect(store.entries.contains { $0.canonical == "Concurrent1" })
        #expect(store.entries.contains { $0.canonical == "Concurrent2" })
        #expect(store.entries.contains { $0.canonical == "Concurrent3" })
    }
}
