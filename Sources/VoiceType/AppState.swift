import Foundation
import Observation

@Observable
final class AppState {
    var isRecording: Bool = false
    var isProcessing: Bool = false
    var rawTranscript: String = ""
    var polishedTranscript: String = ""
    var showingResultPanel: Bool = false
    var showingRawInPanel: Bool = false
    var elapsedRecordingSeconds: Int = 0
    var statusMessage: String = ""
    var processingError: String?
    var audioLevel: Float = 0
    var levelHistory: [Float] = Array(repeating: 0, count: 128)

    func pushLevel(_ level: Float) {
        audioLevel = level
        levelHistory.removeFirst()
        levelHistory.append(level)
    }
}
