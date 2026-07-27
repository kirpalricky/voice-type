import Foundation
import Observation
import OSLog

/// Represents a single glossary entry with a canonical form and known variants
struct GlossaryEntry: Codable, Identifiable {
    let id: UUID
    /// The correct/desired form (e.g., "SuperWhisper", "IAB", "CloudNative")
    let canonical: String
    /// Known mis-transcribed or spoken forms (e.g., ["super whisper", "superwhisper"])
    /// Can be empty for simple entries where there's no separate spoken form
    let variants: [String]

    init(canonical: String, variants: [String] = []) {
        self.id = UUID()
        self.canonical = canonical
        self.variants = variants
    }

    enum CodingKeys: String, CodingKey {
        case id, canonical, variants
    }
}

/// Manages loading, saving, and accessing glossary entries from persistent storage
@MainActor
@Observable
final class GlossaryStore {
    @ObservationIgnored private let fileManager = FileManager.default
    @ObservationIgnored private let logger = OSLog(subsystem: "com.voicetype.glossary", category: "GlossaryStore")
    @ObservationIgnored private let baseDirectoryOverride: URL?

    var entries: [GlossaryEntry] = []

    private var glossaryURL: URL {
        let baseDir: URL
        if let override = baseDirectoryOverride {
            baseDir = override
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            baseDir = appSupport.appendingPathComponent("VoiceType", isDirectory: true)
        }
        return baseDir.appendingPathComponent("glossary.json")
    }

    private var glossaryDir: URL {
        glossaryURL.deletingLastPathComponent()
    }

    init(baseDirectoryOverride: URL? = nil) {
        self.baseDirectoryOverride = baseDirectoryOverride
        load()
    }

    /// Load glossary entries from disk, creating example entries if the file doesn't exist
    func load() {
        do {
            if fileManager.fileExists(atPath: glossaryURL.path) {
                let data = try Data(contentsOf: glossaryURL)
                let decoder = JSONDecoder()
                entries = try decoder.decode([GlossaryEntry].self, from: data)
                os_log("Loaded %d glossary entries", log: self.logger, type: .info, self.entries.count)
            } else {
                // Create example entries on first launch
                seedExampleEntries()
                try save()
                os_log("Created example glossary entries", log: self.logger, type: .info)
            }
        } catch {
            os_log("Failed to load glossary: %@", log: self.logger, type: .error, error.localizedDescription)
            // On error, seed with examples
            seedExampleEntries()
        }
    }

    /// Save glossary entries to disk
    func save() throws {
        // Ensure the directory exists
        try fileManager.createDirectory(at: glossaryDir, withIntermediateDirectories: true, attributes: nil)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: glossaryURL)
        os_log("Saved %d glossary entries", log: self.logger, type: .info, self.entries.count)
    }

    /// Add a new glossary entry
    func add(_ entry: GlossaryEntry) throws {
        entries.append(entry)
        try save()
    }

    /// Remove a glossary entry at the specified index
    func remove(at index: Int) throws {
        guard index >= 0 && index < entries.count else {
            throw GlossaryError.invalidIndex
        }
        entries.remove(at: index)
        try save()
    }

    /// Seed with example entries for first-time setup
    private func seedExampleEntries() {
        entries = [
            // Simple entry (no separate spoken form)
            GlossaryEntry(canonical: "ParakeetDB", variants: []),
            // Phrase-mapping entries
            GlossaryEntry(canonical: "CloudNative", variants: ["cloud native", "cloudnative"]),
            GlossaryEntry(canonical: "SuperWhisper", variants: ["super whisper"])
        ]
    }
}

enum GlossaryError: LocalizedError {
    case invalidIndex

    var errorDescription: String? {
        switch self {
        case .invalidIndex:
            return "Invalid glossary entry index"
        }
    }
}
