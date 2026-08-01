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
    var polishingFailed: Bool = false

    /// True from launch until the Parakeet model has finished loading (or failed to), so the
    /// UI can disable "Start Recording" instead of letting it silently no-op on first use.
    var isModelLoading: Bool = true
    var modelLoadStatus: String = "Loading speech model…"

    static let barCount = 56

    /// Latest raw per-band magnitudes from the audio tap's FFT (see `AudioRecorder`), written
    /// directly from the tap callback. A single scalar level fanned out to many bars was
    /// tried and rejected — every bar being a linear transform of the same value made them
    /// perfectly correlated ("all waves are almost of the same height... entire thing is
    /// blowing up or down"). Real per-band data is what gives each bar independent motion.
    var latestBands: [Float] = Array(repeating: 0, count: AppState.barCount)

    /// What's actually drawn: fixed bar positions that bounce in place, each smoothed
    /// independently from its own band. No scrolling and no position-based remap — a
    /// center-out age-mirrored remap was tried and rejected for still reading as a wave
    /// radiating outward, and a pure history scroll was rejected earlier for looking like
    /// frozen bars sliding left.
    var barLevels: [Float] = Array(repeating: 0, count: AppState.barCount)

    /// Per-band one-pole filter state.
    private var barSmoothed: [Float] = Array(repeating: 0, count: AppState.barCount)

    /// A lagging snapshot of `barLevels`, refreshed every `echoInterval` pushes, rendered
    /// underneath the current bars at low opacity. Gives a fading "echo" of the shape from
    /// ~200ms ago cycling underneath the live one, layering in extra motion/depth on top of
    /// the standing wave without any horizontal scroll.
    var echoBarLevels: [Float] = Array(repeating: 0, count: AppState.barCount)
    private var tickCounter = 0
    private let echoInterval = 6

    /// Pulls the latest FFT band snapshot through a per-band attack/decay envelope at a fixed
    /// cadence (called from a ~30fps UI-side loop), decoupled from the audio tap's own timing
    /// jitter. Fast attack/slow release lets each band pop instantly on onset while still
    /// settling smoothly, instead of a symmetric average that makes rises and falls equally
    /// dull.
    /// Ticks since the current recording's push loop started. Even after `AudioRecorder`
    /// discards its first few buffers and DC-blocks the signal, a residual engine cold-start
    /// transient could still hit bars at full attack speed and read as a visible spike right
    /// as recording begins. Ramping attack up from a gentle 0.15 to the full 0.6 over the
    /// first ~400ms (12 ticks at 30fps) eases bars in instead of letting them snap.
    private var levelTicks = 0
    private let attackRampTicks = 12
    private let fullAttack: Float = 0.6

    func pushLevel() {
        let release: Float = 0.15
        let attack: Float
        if levelTicks >= attackRampTicks {
            attack = fullAttack
        } else {
            attack = 0.15 + (fullAttack - 0.15) * (Float(levelTicks) / Float(attackRampTicks))
        }

        for index in 0..<barSmoothed.count {
            let target = latestBands[index]
            let k = target > barSmoothed[index] ? attack : release
            barSmoothed[index] += (target - barSmoothed[index]) * k
            barLevels[index] = barSmoothed[index]
        }

        levelTicks += 1
        tickCounter += 1
        if tickCounter % echoInterval == 0 {
            echoBarLevels = barLevels
        }
    }

    /// Resets the standing wave to flat, so a new recording doesn't start mid-bounce from
    /// the previous one.
    func resetLevels() {
        latestBands = Array(repeating: 0, count: AppState.barCount)
        barLevels = Array(repeating: 0, count: AppState.barCount)
        barSmoothed = Array(repeating: 0, count: AppState.barCount)
        echoBarLevels = Array(repeating: 0, count: AppState.barCount)
        tickCounter = 0
        levelTicks = 0
    }
}
