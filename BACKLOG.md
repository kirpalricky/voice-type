# Backlog

## Open

- **Eager model download on launch.** Currently the Parakeet model is
  loaded lazily on first `stopRecordingAndTranscribe()`
  ([VoiceTypeApp.swift:116-122](Sources/VoiceType/VoiceTypeApp.swift)),
  so the first recording after a fresh install/cache-purge has to wait
  for a multi-hundred-MB download before transcribing. Instead:
  - Kick off `transcriber.initialize(onProgress:)` in the background as
    soon as the app launches (e.g. from `VoiceTypeApp.init()` or a
    `.task` on the menu bar scene), not on first use.
  - Surface download/compile progress in the menu bar (icon state and/or
    the menu list), reusing `appState.statusMessage` /
    `onProgress` plumbing already in place.
  - Disable "Start Recording" (menu item + `⌘⇧D` hotkey) until the model
    finishes loading, with a clear affordance (dimmed item, progress %,
    or tooltip) instead of a silent no-op.
  - `Transcriber.initialize()` is already idempotent (`guard !isInitialized`)
    and self-healing (purges an incomplete cache — see
    [Transcriber.swift](Sources/VoiceType/Transcriber.swift)), so this is
    mainly UI/lifecycle wiring, not new download logic.

- XCTest suite for `VocabularyMatcher` / `Glossary` / Levenshtein — zero
  tests exist currently.

## Done

- Fixed record/stop crash (AVAudioEngine reuse), History persistence,
  packaging script, model-cache repair on incomplete download — see
  commit `4534e88`.
