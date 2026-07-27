import AppKit
import SwiftUI
import KeyboardShortcuts

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case vocabulary
    case history
    case about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .vocabulary: return "Vocabulary"
        case .history: return "History"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .vocabulary: return "book"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @State private var selectedSection: SettingsSection
    var glossaryStore: GlossaryStore
    var historyStore: HistoryStore

    init(glossaryStore: GlossaryStore, historyStore: HistoryStore, initialSection: SettingsSection = .general) {
        self.glossaryStore = glossaryStore
        self.historyStore = historyStore
        self._selectedSection = State(initialValue: initialSection)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.label, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            Group {
                switch selectedSection {
                case .general:
                    GeneralSettingsTab(historyStore: historyStore)
                case .vocabulary:
                    VocabularySettingsTab(glossaryStore: glossaryStore)
                case .history:
                    HistorySettingsTab(historyStore: historyStore)
                case .about:
                    AboutSettingsTab()
                }
            }
            .navigationTitle(selectedSection.label)
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

struct GeneralSettingsTab: View {
    var historyStore: HistoryStore

    var body: some View {
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
                .padding(.vertical, 4)
            }

            Section(header: Text("Storage"), footer: Text("Transcripts and recordings are saved here.").font(.caption).foregroundColor(.secondary)) {
                HStack {
                    Text(historyStore.baseDir.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([historyStore.baseDir])
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
    }
}

private struct Acknowledgment: Identifiable {
    let id = UUID()
    let name: String
    let purpose: String
    let url: String
}

struct AboutSettingsTab: View {
    private static let acknowledgments: [Acknowledgment] = [
        Acknowledgment(name: "FluidAudio", purpose: "On-device speech recognition (Parakeet model)", url: "https://github.com/FluidInference/FluidAudio"),
        Acknowledgment(name: "KeyboardShortcuts", purpose: "Global hotkey recording and handling", url: "https://github.com/sindresorhus/KeyboardShortcuts")
    ]

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    @State private var diagnosticLoggingEnabled = DiagnosticLogger.shared.isEnabled
    @State private var showingClearLogConfirmation = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VoiceType")
                        .font(.title2.bold())
                    Text("Version \(version) (\(build))")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section(header: Text("Diagnostics")) {
                Toggle("Enable diagnostic logging", isOn: $diagnosticLoggingEnabled)
                    .onChange(of: diagnosticLoggingEnabled) { _, newValue in
                        DiagnosticLogger.shared.isEnabled = newValue
                    }
                Text("Writes app lifecycle and recording/transcription events to a log file — useful when reporting an issue. Off by default; does not include transcript text.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Button("Reveal Log in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLogger.shared.logFileURL])
                    }
                    Button("Clear Log") {
                        showingClearLogConfirmation = true
                    }
                }
                .padding(.top, 2)
            }
            .confirmationDialog(
                "Clear the diagnostics log?",
                isPresented: $showingClearLogConfirmation
            ) {
                Button("Clear Log", role: .destructive) {
                    DiagnosticLogger.shared.clearLog()
                }
                Button("Cancel", role: .cancel) {}
            }

            Section(header: Text("Open Source Acknowledgments")) {
                ForEach(Self.acknowledgments) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.body.weight(.medium))
                        Text(item.purpose)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(item.url)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.accentColor)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section(header: Text("License")) {
                Text("VoiceType is provided as-is, with no warranty of any kind. Third-party components above are used under their respective open-source licenses — see each project's repository for full license terms.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }
}

struct VocabularySettingsTab: View {
    var glossaryStore: GlossaryStore

    @State private var newTerm = ""
    @State private var newVariants = ""
    @State private var errorMessage: String?

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
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        ), presenting: errorMessage) { _ in
            Button("OK") {
                errorMessage = nil
            }
        } message: { errorMsg in
            Text(errorMsg)
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
        do {
            try glossaryStore.add(entry)
            newTerm = ""
            newVariants = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteEntry(at index: Int) {
        do {
            try glossaryStore.remove(at: index)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct HistorySettingsTab: View {
    var historyStore: HistoryStore

    @State private var selectedEntryID: UUID?
    @State private var searchText = ""
    @State private var showingRawInDetail = false

    var filteredEntries: [HistoryEntry] {
        if searchText.isEmpty {
            return historyStore.entries
        }
        return historyStore.entries.filter { entry in
            entry.rawTranscript.localizedCaseInsensitiveContains(searchText) ||
            entry.polishedTranscript.localizedCaseInsensitiveContains(searchText)
        }
    }

    var selectedEntry: HistoryEntry? {
        filteredEntries.first { $0.id == selectedEntryID }
    }

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
                HStack(spacing: 0) {
                    // Master column: list of entries
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField("Search transcripts", text: $searchText)
                                .textFieldStyle(.plain)
                        }
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)

                        List(selection: $selectedEntryID) {
                            ForEach(filteredEntries) { entry in
                                HistoryRow(entry: entry, historyStore: historyStore)
                                    .tag(entry.id)
                            }
                        }
                    }
                    .frame(minWidth: 250)

                    Divider()

                    // Detail column: full transcript view
                    VStack(spacing: 12) {
                        if let entry = selectedEntry {
                            HStack(spacing: 8) {
                                Button(action: { showingRawInDetail = false }) {
                                    Text("Polished")
                                        .font(.caption)
                                        .padding(.vertical, 4)
                                        .padding(.horizontal, 8)
                                        .background(showingRawInDetail ? Color.clear : Color(nsColor: .controlBackgroundColor))
                                        .cornerRadius(4)
                                }
                                .buttonStyle(.plain)

                                Button(action: { showingRawInDetail = true }) {
                                    Text("Raw")
                                        .font(.caption)
                                        .padding(.vertical, 4)
                                        .padding(.horizontal, 8)
                                        .background(showingRawInDetail ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                                        .cornerRadius(4)
                                }
                                .buttonStyle(.plain)

                                Spacer()
                            }

                            ScrollView {
                                VStack(alignment: .leading, spacing: 0) {
                                    let displayText = showingRawInDetail ? entry.rawTranscript : entry.polishedTranscript
                                    Text(displayText.isEmpty ? "(no speech detected)" : displayText)
                                        .font(.body)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.left")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                                Text("Select an entry to view details")
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onChange(of: selectedEntryID) { oldID, newID in
            if let entry = selectedEntry {
                if entry.polishedTranscript.isEmpty && !entry.rawTranscript.isEmpty {
                    showingRawInDetail = true
                } else {
                    showingRawInDetail = false
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
