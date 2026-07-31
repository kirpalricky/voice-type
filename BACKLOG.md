# Backlog

## Open (stack ranked)

1. **History storage scale-up, Stage 2 — Decouple entry paths from
   folder-name-as-ID.** Add `folderURL: URL` to `HistoryEntry`, populate
   at load/add time. Switch authoritative ID from folder name to
   `metadata.id` (currently `load()` explicitly ignores `metadata.id` in
   favor of the folder name — flip this). Replace the 3 hardcoded
   `recordingsDir.appendingPathComponent(id.uuidString)` call sites
   (`addEntry`, `audioURL(for:)`, `deleteFolder(for:)`) with
   `entry.folderURL`.
   - **Why:** makes folder layout a property of data rather than a
     formula — prerequisite for Stage 6 and for any future layout
     change to be safe/reversible.

2. **History storage scale-up, Stage 3 — History UI perf fixes.** In
   `SettingsView.swift`: precompute a lowercased search haystack per
   entry (avoid `localizedCaseInsensitiveContains` — ICU collation —
   recomputing in `body` every keystroke), debounce search ~150ms via
   `.onChange(of: searchText)`, fix `selectedEntry` to look up by ID
   directly instead of re-filtering `filteredEntries`, and cache a
   `hasAudio` flag on the entry so `HistoryRow` stops calling
   `fileExists` on every row render.
   - **Why:** invisible at 100 entries, will visibly lag at thousands.

3. **History storage scale-up, Stage 4 — Async startup load + index
   cache.** `HistoryStore()` currently does a synchronous full-directory
   scan in `init` (`VoiceTypeApp.swift:12`), blocking hotkey
   registration at launch. Add a `Recordings/index.json` cache (written
   on add/delete) that launch reads first, falling back to a full scan
   only if missing/stale; move the fallback scan off the main thread.
   - **Why:** must land before Stage 5 raises the entry cap, or launch
     time regresses hard.

4. **History storage scale-up, Stage 5 — Raise `maxEntries` to 5000.**
   Single count-based cap for both transcripts and audio (user
   explicitly deferred a separate audio byte/age budget — revisit later
   if disk usage becomes a concern, mitigated significantly by Stage 1's
   ~16x size cut). Also: run the prune pass after `load()` (currently
   only runs inside `addEntry`, so a lowered cap or an already-over-cap
   disk state never gets pruned), and fix the phantom-entry bug in
   `addEntry`'s failure path (a folder-write failure removes the folder
   but still inserts the entry into `entries`, producing an in-memory
   entry with no backing folder that silently no-ops on delete).

5. **History storage scale-up, Stage 6 (optional/deferred) — Cosmetic
   sortable folder names.** Rename UUID folders to
   `<yyyyMMdd-HHmmss>-<uuid>` for Finder chronological sort. Depends on
   Stage 2 landing first (folder name must stop being the authoritative
   ID before it's safe to change). Best-effort, idempotent migration on
   load; skip any folder that errors.

6. **Reprocess history entries from raw audio.** `HistoryStore`
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
