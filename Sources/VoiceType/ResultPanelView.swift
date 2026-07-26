import SwiftUI

struct ResultPanelView: View {
    var appState: AppState
    var onDismiss: () -> Void

    @State private var isBlinking = false

    var body: some View {
        VStack(spacing: 12) {
            if appState.isRecording {
                recordingView
            } else if !appState.polishedTranscript.isEmpty || !appState.rawTranscript.isEmpty {
                resultView
            }
        }
        .padding(12)
        .frame(maxWidth: 400)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .shadow(radius: 8)
    }

    private var recordingView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                // Pulsing red dot
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .opacity(isBlinking ? 1.0 : 0.5)
                    .animation(.easeInOut(duration: 0.6).repeatForever(), value: isBlinking)

                Text("Recording…")
                    .font(.system(.body, design: .default))

                Spacer()

                Text(formattedTime)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            isBlinking = true
        }
    }

    private var resultView: some View {
        VStack(spacing: 12) {
            // Segmented control
            HStack {
                Button(action: { appState.showingRawInPanel = false }) {
                    Text("Polished")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(appState.showingRawInPanel ? .gray : .blue)

                Button(action: { appState.showingRawInPanel = true }) {
                    Text("Raw")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(appState.showingRawInPanel ? .blue : .gray)
            }

            // Text display
            ScrollView {
                Text(appState.showingRawInPanel ? appState.rawTranscript : appState.polishedTranscript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(.body, design: .default))
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(4)
            }
            .frame(minHeight: 60, maxHeight: 150)

            // Action buttons
            HStack(spacing: 8) {
                Button(action: copyToClipboard) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered)
                .help("Dismiss")
            }
        }
    }

    private var formattedTime: String {
        let minutes = appState.elapsedRecordingSeconds / 60
        let seconds = appState.elapsedRecordingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func copyToClipboard() {
        let textToCopy = appState.showingRawInPanel ? appState.rawTranscript : appState.polishedTranscript
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textToCopy, forType: .string)
        onDismiss()
    }
}
