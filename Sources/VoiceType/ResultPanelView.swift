import SwiftUI

struct ResultPanelView: View {
    var appState: AppState
    var onDismiss: () -> Void
    var onCancel: () -> Void
    var onStopRecording: () -> Void
    var onDismissError: () -> Void

    @State private var isBlinking = false

    var body: some View {
        VStack(spacing: 12) {
            if appState.isRecording {
                recordingView
            } else if appState.isProcessing {
                processingView
            } else if let error = appState.processingError {
                errorView(error)
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
        VStack(spacing: 10) {
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

            levelMeter

            HStack {
                Spacer()
                Button(action: onStopRecording) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .onAppear {
            isBlinking = true
        }
        .task(id: appState.isRecording) {
            // Paces the per-band envelope at a fixed cadence, decoupled from the audio tap's
            // own ~100ms buffer jitter, so bars advance evenly instead of in uneven bursts.
            guard appState.isRecording else { return }
            while !Task.isCancelled {
                appState.pushLevel()
                try? await Task.sleep(nanoseconds: 33_000_000) // ~30fps
            }
        }
    }

    /// Live standing-wave meter: bars sit at fixed positions and pulse in place, each driven
    /// by its own real FFT frequency band (see `AudioRecorder.computeBands`) rather than a
    /// scrolling strip chart or one scalar fanned out to every bar — both were tried and
    /// rejected (frozen bars sliding left; a wave visibly radiating from the center; all
    /// bars moving in an undifferentiated block). Real per-band data gives each bar
    /// independent motion with no scroll and no directional propagation. A fading echo of
    /// the shape from ~200ms ago is drawn underneath for extra depth. Single Canvas pass —
    /// no per-view identity, no animation modifiers (both caused a "wiggle" bug earlier);
    /// bar positions/widths are pixel-snapped (fractional edges caused a Moiré bug earlier).
    private var levelMeter: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let barCount = appState.barLevels.count
                guard barCount > 0 else { return }

                let spacing: CGFloat = 4
                let slot = size.width / CGFloat(barCount)
                let baseBarWidth = max((slot - spacing).rounded(), 1)
                let midY = size.height / 2
                let mid = CGFloat(barCount - 1) / 2
                let t = timeline.date.timeIntervalSinceReferenceDate
                let pulse = 0.5 + 0.5 * sin(t * 2.2)

                func draw(_ levels: [Float], opacityScale: CGFloat, glow: Bool) {
                    for (index, level) in levels.enumerated() {
                        let lvl = CGFloat(level)

                        // Idle floor: a slow global pulse plus per-bar jitter so silence still
                        // feels alive instead of collapsing to a dead flat line.
                        let jitter = 0.5 + 0.5 * sin(t * 3 + Double(index) * 0.9)
                        let idleFloor = 3 + 4 * CGFloat(pulse) + 3 * CGFloat(jitter)
                        let height = max(lvl * size.height, idleFloor)

                        // Brightness tracks amplitude (loud = bright white, quiet = dim) with
                        // a gentle center-favoring fade so the row isn't uniformly flat. A
                        // gamma curve on `lvl` pushes quiet/mid bars down harder than a
                        // linear map would, widening the perceived loud/quiet contrast while
                        // the floor keeps quiet bars dim but still visibly present.
                        let posFade = 1 - pow(abs(CGFloat(index) - mid) / max(mid, 1), 1.6) * 0.35
                        let shaped = pow(lvl, 1.4)
                        let opacity = (0.22 + 0.78 * shaped) * posFade * opacityScale

                        // Static per-index width profile breaks the grid-like uniformity
                        // without jittering width frame-to-frame (which reads as noise, not
                        // organic variation).
                        let widthScale = 0.7 + 0.6 * abs(sin(Double(index) * 1.7))
                        let barWidth = max((baseBarWidth * CGFloat(widthScale)).rounded(), 1)

                        let slotCenter = (CGFloat(index) + 0.5) * slot
                        let x = (slotCenter - barWidth / 2).rounded()
                        let rect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
                        let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)

                        if glow {
                            let glowRect = rect.insetBy(dx: -1.5, dy: -1.5)
                            context.fill(
                                Path(roundedRect: glowRect, cornerRadius: barWidth / 2 + 1.5),
                                with: .color(.white.opacity(opacity * 0.18))
                            )
                        }
                        context.fill(path, with: .color(.white.opacity(opacity)))
                    }
                }

                draw(appState.echoBarLevels, opacityScale: 0.35, glow: false)
                draw(appState.barLevels, opacityScale: 1.0, glow: true)
            }
        }
        .frame(height: 100)
    }

    private var processingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text(appState.statusMessage.isEmpty ? "Processing…" : appState.statusMessage)
                .font(.system(.body, design: .default))
                .lineLimit(1)

            Spacer()

            Button(action: onCancel) {
                Text("Cancel")
            }
            .buttonStyle(.bordered)
        }
    }

    private func errorView(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)

            Text(message)
                .font(.system(.body, design: .default))
                .lineLimit(2)

            Spacer()

            Button(action: onDismissError) {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.bordered)
            .help("Dismiss")
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
