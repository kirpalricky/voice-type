import SwiftUI
import AppKit

class ResultPanelWindow {
    private var panel: NSPanel?
    private let appState: AppState
    private let onCancel: () -> Void
    private let onStopRecording: () -> Void
    private let onDismissError: () -> Void
    private var dismissalTimer: Timer?
    private var recordingTimer: Timer?
    private var positionObserver: NSObjectProtocol?

    init(
        appState: AppState,
        onCancel: @escaping () -> Void,
        onStopRecording: @escaping () -> Void,
        onDismissError: @escaping () -> Void
    ) {
        self.appState = appState
        self.onCancel = onCancel
        self.onStopRecording = onStopRecording
        self.onDismissError = onDismissError
    }

    func show() {
        // Create the panel if it doesn't exist
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .clear

            // Enable dragging by clicking on background areas
            panel.isMovable = true
            panel.isMovableByWindowBackground = true

            // Create the SwiftUI view
            let resultView = ResultPanelView(
                appState: appState,
                onDismiss: { [weak self] in
                    self?.hide()
                },
                onCancel: onCancel,
                onStopRecording: onStopRecording,
                onDismissError: onDismissError
            )

            let hostingView = NSHostingView(rootView: resultView)
            panel.contentView = hostingView

            // Restore saved position or use default positioning
            let positionRestored = restoreSavedPosition(for: panel)
            if !positionRestored {
                // Center the panel on the main screen as fallback
                if let mainScreen = NSScreen.main {
                    let screenFrame = mainScreen.frame
                    let panelSize = CGSize(width: 400, height: 240)
                    let x = (screenFrame.width - panelSize.width) / 2
                    let y = screenFrame.height * 0.2 // Position at 20% from top
                    panel.setFrameTopLeftPoint(CGPoint(x: x, y: screenFrame.height - y))
                }
            }

            self.panel = panel

            // Register notification observer to save position when panel moves
            registerPositionObserver(for: panel)
        }

        panel?.orderFront(nil)
        startRecordingTimer()
        startDismissalTimer()
    }

    func hide() {
        panel?.orderOut(nil)
        stopRecordingTimer()
        stopDismissalTimer()
    }

    private func startRecordingTimer() {
        // Update the elapsed seconds every 0.1 seconds for smooth updates
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, self.appState.isRecording else {
                self?.stopRecordingTimer()
                return
            }
            // This happens naturally as the timer progresses - just keep it ticking
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func startDismissalTimer() {
        // Auto-dismiss after 15 seconds of showing the result (not recording)
        dismissalTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if !self.appState.isRecording && !self.appState.isProcessing {
                self.hide()
            }
        }
    }

    private func stopDismissalTimer() {
        dismissalTimer?.invalidate()
        dismissalTimer = nil
    }

    // MARK: - Position Persistence

    private func registerPositionObserver(for panel: NSPanel) {
        unregisterPositionObserver()
        positionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.savePanelPosition(panel)
        }
    }

    private func unregisterPositionObserver() {
        if let observer = positionObserver {
            NotificationCenter.default.removeObserver(observer)
            positionObserver = nil
        }
    }

    private func savePanelPosition(_ panel: NSPanel) {
        let origin = panel.frame.origin
        UserDefaults.standard.set(
            ["x": origin.x, "y": origin.y],
            forKey: "ResultPanelOrigin"
        )
    }

    private func restoreSavedPosition(for panel: NSPanel) -> Bool {
        guard let saved = UserDefaults.standard.dictionary(forKey: "ResultPanelOrigin"),
              let x = saved["x"] as? CGFloat,
              let y = saved["y"] as? CGFloat else {
            return false
        }

        let savedOrigin = CGPoint(x: x, y: y)

        // Validate the saved position is still on a visible screen
        if isPositionOnScreen(savedOrigin) {
            panel.setFrameOrigin(savedOrigin)
            return true
        }

        return false
    }

    private func isPositionOnScreen(_ origin: CGPoint) -> Bool {
        // Check if a point roughly 20pt inset from the origin is contained within any screen's frame
        let testPoint = CGPoint(x: origin.x + 20, y: origin.y + 20)

        for screen in NSScreen.screens {
            if screen.frame.contains(testPoint) {
                return true
            }
        }

        return false
    }

    deinit {
        stopRecordingTimer()
        stopDismissalTimer()
        unregisterPositionObserver()
    }
}
