# Backlog

## Open (stack ranked)

1. **Reprocess history entries from raw audio.** `HistoryStore`
  ([HistoryStore.swift](Sources/VoiceType/HistoryStore.swift)) already
  saves the source audio per entry (`audioFileName`, `audioURL(for:)`),
  but there's no way to re-run transcription/polishing on it after the
  fact. Useful when we ship an ASR or `Enhancer` prompt change and want
  better output for past recordings without re-recording:
  - Add a "Reprocess" action in the History browser (`HistoryStore` +
    its UI) that re-runs the saved audio through
    `TranscriptionCoordinator` (transcription, then polishing) and
    updates the entry's `rawTranscript` / `polishedTranscript` in
    place (or appends a new version, TBD).
  - Handle entries with no saved audio (`audioFileName == nil`) —
    disable the action or show why it's unavailable.
  - Consider a bulk "reprocess all" for after a model/prompt upgrade.
  - **Why P1:** compounds every future ASR/Enhancer quality
    improvement onto past recordings, but best done once the polishing
    pipeline (currently under active iteration) settles down.

## Done

- Draggable recording panel. `ResultPanelWindow.swift` now sets
  `panel.isMovable`/`isMovableByWindowBackground = true`, and persists
  the panel's origin to `UserDefaults` on `NSWindow.didMoveNotification`,
  restoring it on next `show()` (falling back to the centered default if
  the saved position is no longer on any connected screen).

- Fixed record/stop crash (AVAudioEngine reuse), History persistence,
  packaging script, model-cache repair on incomplete download — see
  commit `4534e88`.

- XCTest suite for `VocabularyMatcher` / `Glossary` / Levenshtein —
  covered by `VocabularyMatcherTests.swift` (23 cases) and
  `GlossaryStoreTests.swift` (13 cases) using Swift Testing (`@Test`).

- Eager model download on launch. `TranscriptionCoordinator.preloadModel()`
  is kicked off from `VoiceTypeApp.init()` on a background `Task`, disables
  "Start Recording" (menu item + hotkey) via `AppState.isModelLoading`
  until the model finishes loading (or fails, falling back to the existing
  lazy-load-on-first-use path), and surfaces progress via
  `AppState.modelLoadStatus` and a menu bar download icon.
