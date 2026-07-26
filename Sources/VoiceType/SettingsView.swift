import AppKit
import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @State private var selectedTab: Int
    var glossaryStore: GlossaryStore
    var historyStore: HistoryStore

    init(glossaryStore: GlossaryStore, historyStore: HistoryStore, initialTab: Int = 0) {
        self.glossaryStore = glossaryStore
        self.historyStore = historyStore
        self._selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab(historyStore: historyStore)
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(0)

            VocabularySettingsTab(glossaryStore: glossaryStore)
                .tabItem {
                    Label("Vocabulary", systemImage: "book")
                }
                .tag(1)

            HistorySettingsTab(historyStore: historyStore)
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(2)
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

struct GeneralSettingsTab: View {
    var historyStore: HistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Form {
                Section(header: Text("Hotkey")) {
                    KeyboardShortcuts.Recorder("Record hotkey:", name: .toggleRecording)
                }

                Section(header: Text("Apple Intelligence")) {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Enhancer.isAvailable ? Color.green : Color.red)
                            .frame(width: 10, height: 10)

                        Text(Enhancer.isAvailable ? "Available" : "Unavailable")
                            .foregroundColor(Enhancer.isAvailable ? .green : .red)

                        Spacer()
                    }
                    .padding(.vertical, 8)
                }

                Section(header: Text("Storage")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Transcripts and recordings are saved to:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(historyStore.baseDir.path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([historyStore.baseDir])
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Spacer()
        }
        .padding(20)
    }
}

struct VocabularySettingsTab: View {
    var glossaryStore: GlossaryStore

    @State private var newTerm = ""
    @State private var newVariants = ""

    var body: some View {
        VStack(spacing: 0) {
            // Add entry form
            VStack(alignment: .leading, spacing: 12) {
                Text("Add New Entry")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Term:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., SuperWhisper", text: $newTerm)
                        .textFieldStyle(.roundedBorder)

                    Text("Variants (optional, comma-separated):")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., super whisper, superwhisper", text: $newVariants)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Button(action: addEntry) {
                        Text("Add Entry")
                    }
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)

                    Spacer()
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Glossary list
            List {
                ForEach(glossaryStore.entries.indices, id: \.self) { index in
                    let entry = glossaryStore.entries[index]
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            if entry.variants.isEmpty {
                                Text(entry.canonical)
                                    .font(.body)
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.canonical)
                                        .font(.body)
                                    Text(entry.variants.prefix(1).joined(separator: ", ") + (entry.variants.count > 1 ? " +\(entry.variants.count - 1) more" : ""))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Spacer()

                        Button(action: {
                            deleteEntry(at: index)
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Delete entry")
                    }
                    .contentShape(Rectangle())
                }
            }
        }
    }

    private func addEntry() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }

        let variantsString = newVariants.trimmingCharacters(in: .whitespaces)
        let variants = variantsString.isEmpty
            ? []
            : variantsString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        let entry = GlossaryEntry(canonical: term, variants: variants)
        try? glossaryStore.add(entry)

        newTerm = ""
        newVariants = ""
    }

    private func deleteEntry(at index: Int) {
        try? glossaryStore.remove(at: index)
    }
}

struct HistorySettingsTab: View {
    var historyStore: HistoryStore

    @State private var selectedEntryID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transcripts and recordings are saved to \(historyStore.baseDir.path)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([historyStore.baseDir])
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if historyStore.entries.isEmpty {
                Spacer()
                Text("No recordings yet")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List(selection: $selectedEntryID) {
                    ForEach(historyStore.entries) { entry in
                        HistoryRow(entry: entry, historyStore: historyStore)
                            .tag(entry.id)
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    var historyStore: HistoryStore

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.dateFormatter.string(from: entry.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)

                let text = entry.polishedTranscript.isEmpty ? entry.rawTranscript : entry.polishedTranscript
                Text(text.isEmpty ? "(no speech detected)" : text)
                    .font(.body)
                    .lineLimit(3)
            }

            Spacer()

            HStack(spacing: 8) {
                Button(action: copyToClipboard) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy transcript")

                if let audioURL = historyStore.audioURL(for: entry) {
                    Button(action: {
                        NSWorkspace.shared.activateFileViewerSelecting([audioURL])
                    }) {
                        Image(systemName: "waveform")
                    }
                    .buttonStyle(.plain)
                    .help("Reveal audio in Finder")
                }

                Button(action: { historyStore.delete(entry) }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Delete entry")
            }
        }
        .padding(.vertical, 4)
    }

    private func copyToClipboard() {
        let text = entry.polishedTranscript.isEmpty ? entry.rawTranscript : entry.polishedTranscript
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
