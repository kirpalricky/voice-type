import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @State private var selectedTab = 0
    var glossaryStore: GlossaryStore

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(0)

            VocabularySettingsTab(glossaryStore: glossaryStore)
                .tabItem {
                    Label("Vocabulary", systemImage: "book")
                }
                .tag(1)
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

struct GeneralSettingsTab: View {
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
