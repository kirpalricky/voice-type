import SwiftUI
import AppKit

class ResultPanelWindow {
    private var panel: NSPanel?
    private let appState: AppState
    private var dismissalTimer: Timer?
    private var recordingTimer: Timer?

    init(appState: AppState) {
        self.appState = appState
    }

    func show() {
        // Create the panel if it doesn't exist
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .clear

            // Create the SwiftUI view
            let resultView = ResultPanelView(
                appState: appState,
                onDismiss: { [weak self] in
                    self?.hide()
                }
            )

            let hostingView = NSHostingView(rootView: resultView)
            panel.contentView = hostingView

            // Center the panel on the main screen
            if let mainScreen = NSScreen.main {
                let screenFrame = mainScreen.frame
                let panelSize = CGSize(width: 400, height: 200)
                let x = (screenFrame.width - panelSize.width) / 2
                let y = screenFrame.height * 0.2 // Position at 20% from top
                panel.setFrameTopLeftPoint(CGPoint(x: x, y: screenFrame.height - y))
            }

            self.panel = panel
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
            if !self.appState.isRecording {
                self.hide()
            }
        }
    }

    private func stopDismissalTimer() {
        dismissalTimer?.invalidate()
        dismissalTimer = nil
    }

    deinit {
        stopRecordingTimer()
        stopDismissalTimer()
    }
}
