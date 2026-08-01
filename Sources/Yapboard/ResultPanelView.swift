import SwiftUI

struct ResultPanelView: View {
    var appState: AppState
    var onDismiss: () -> Void
    var onCancel: () -> Void
    var onStopRecording: () -> Void
    var onDismissError: () -> Void

    @State private var isPinging = false
    @Namespace private var segmentNamespace

    // MARK: - Design constants

    /// The panel renders inside a single fixed canvas in every state so the window never
    /// resizes as content changes. `outerMargin` reserves room for the drop shadow to breathe
    /// against the (clear) NSPanel background; `Metrics.canvas*` must match the panel's
    /// contentRect in ResultPanelWindow.
    private enum Metrics {
        static let canvasWidth: CGFloat = 400
        static let canvasHeight: CGFloat = 240
        static let outerMargin: CGFloat = 12
        static let cornerRadius: CGFloat = 18
        static let contentPadding: CGFloat = 18
    }

    var body: some View {
        ZStack {
            content
                .padding(Metrics.contentPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cardBackground)
        .padding(Metrics.outerMargin)
        .frame(width: Metrics.canvasWidth, height: Metrics.canvasHeight, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        Group {
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
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.22), value: stateID)
    }

    /// Distinguishes the four render states so the crossfade only fires on real transitions.
    private var stateID: Int {
        if appState.isRecording { return 0 }
        if appState.isProcessing { return 1 }
        if appState.processingError != nil { return 2 }
        return 3
    }

    // MARK: - Card chrome

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                // Hairline that reads as a crisp edge in both appearances, since the panel
                // floats over arbitrary desktop content.
                RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 11, x: 0, y: 5)
    }

    // MARK: - Recording

    private var recordingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                recordingIndicator

                Text("Recording")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                Text(formattedTime)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
            }

            levelMeter(tint: .primary)
                .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                Button(action: onStopRecording) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(FilledButtonStyle(fullWidth: false))
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Solid black/white dot with a radar-style ping ring — a calmer, more intentional "live" cue
    /// than a hard blink.
    private var recordingIndicator: some View {
        ZStack {
            Circle()
                .stroke(Color.primary, lineWidth: 1.5)
                .frame(width: 10, height: 10)
                .scaleEffect(isPinging ? 2.2 : 1)
                .opacity(isPinging ? 0 : 0.7)
                .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: isPinging)

            Circle()
                .fill(Color.primary)
                .frame(width: 10, height: 10)
                .shadow(color: .primary.opacity(0.35), radius: 3)
        }
        .frame(width: 24, height: 24)
        .onAppear { isPinging = true }
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
    private func levelMeter(tint: Color) -> some View {
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
                        let height = max(lvl * size.height * 0.7, idleFloor)

                        // Opacity tracks amplitude (loud = fully opaque, quiet = dim) with
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
                                with: .color(tint.opacity(opacity * 0.18))
                            )
                        }
                        context.fill(path, with: .color(tint.opacity(opacity)))
                    }
                }

                draw(appState.echoBarLevels, opacityScale: 0.35, glow: false)
                draw(appState.barLevels, opacityScale: 1.0, glow: true)
            }
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

    // MARK: - Processing

    private var processingView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ProgressView()
                .controlSize(.large)
                .scaleEffect(1.1)

            Text(appState.statusMessage.isEmpty ? "Processing…" : appState.statusMessage)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.top, 16)

            Text("Polishing your transcript on-device")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 3)

            Spacer(minLength: 0)

            Button("Cancel", action: onCancel)
                .buttonStyle(GhostButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)

            Text("Something went wrong")
                .font(.headline)
                .padding(.top, 12)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.top, 3)

            Spacer(minLength: 0)

            Button("Dismiss", action: onDismissError)
                .buttonStyle(GhostButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Result

    private var resultView: some View {
        VStack(spacing: 12) {
            segmentedControl

            if appState.polishingFailed {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Polishing unavailable — showing raw transcript")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            transcriptWell

            HStack(spacing: 10) {
                Button(action: copyToClipboard) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(FilledButtonStyle(fullWidth: true))

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(QuietIconButtonStyle())
                .help("Dismiss")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var segmentedControl: some View {
        HStack(spacing: 4) {
            segment(title: "Polished", isSelected: !appState.showingRawInPanel) {
                appState.showingRawInPanel = false
            }
            segment(title: "Raw", isSelected: appState.showingRawInPanel) {
                appState.showingRawInPanel = true
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
    }

    private func segment(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { action() }
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.background)
                            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                            .matchedGeometryEffect(id: "segmentHighlight", in: segmentNamespace)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var transcriptWell: some View {
        ScrollView {
            Text(appState.showingRawInPanel ? appState.rawTranscript : appState.polishedTranscript)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - Helpers

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

// MARK: - Button styles

/// Solid, monochromatic primary action with hover and press feedback.
private struct FilledButtonStyle: ButtonStyle {
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        FilledButtonLabel(
            label: configuration.label,
            isPressed: configuration.isPressed,
            fullWidth: fullWidth
        )
    }
}

/// Inner view to hold hover state, which can't be stored directly in ButtonStyle.
private struct FilledButtonLabel<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let fullWidth: Bool

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary)
            )
            .opacity(
                isPressed ? 0.85 : (isHovered ? 0.92 : 1.0)
            )
            .scaleEffect(isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

/// Quiet, icon-only affordance (dismiss). Square with a faint recessed fill so it reads as
/// tappable without competing with the primary action.
private struct QuietIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietIconButtonLabel(
            label: configuration.label,
            isPressed: configuration.isPressed
        )
    }
}

/// Inner view to hold hover state for QuietIconButtonStyle.
private struct QuietIconButtonLabel<Label: View>: View {
    let label: Label
    let isPressed: Bool

    @State private var isHovered = false

    var body: some View {
        label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.quaternary.opacity(
                        isPressed ? 0.9 : (isHovered ? 0.6 : 0.45)
                    ))
            )
            .contentShape(Rectangle())
            .opacity(isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

/// Low-emphasis text button (Cancel / Dismiss on the centered states).
private struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostButtonLabel(
            label: configuration.label,
            isPressed: configuration.isPressed
        )
    }
}

/// Inner view to hold hover state for GhostButtonStyle.
private struct GhostButtonLabel<Label: View>: View {
    let label: Label
    let isPressed: Bool

    @State private var isHovered = false

    var body: some View {
        label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 18)
            .background(
                Capsule().fill(.quaternary.opacity(
                    isPressed ? 0.8 : (isHovered ? 0.6 : 0.45)
                ))
            )
            .contentShape(Capsule())
            .opacity(isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
