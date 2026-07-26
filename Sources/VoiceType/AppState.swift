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
}
