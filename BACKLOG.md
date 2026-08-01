# Backlog

## Open (stack ranked)

1. **Homebrew cask ships with `sha256 :no_check`.**
   ([Casks/yapboard.rb](https://github.com/kirpalricky/homebrew-yapboard/blob/main/Casks/yapboard.rb)
   in the tap repo) — placeholder until the first real release exists to
   hash. After running `scripts/release.sh` for the first time, compute
   `shasum -a 256` on the published zip, replace `:no_check` with the real
   digest, and push to the tap. Blocks nothing today (no release has been
   cut yet) but must happen before the first `brew install` — `:no_check`
   permanently disables integrity verification if left in place.

2. **No CI-driven release pipeline; `scripts/release.sh` only runs
   locally.** `.github/workflows/ci.yml` still only does `swift build` /
   `swift test` on push/PR — nothing runs `scripts/release.sh`, so cutting
   a release is entirely manual on one machine. Also no lint/static
   analysis gate (e.g. SwiftLint) in CI. Consider a manually-triggered
   `workflow_dispatch` job that runs `scripts/release.sh` (would need the
   ad-hoc signing identity and `gh` auth as repo secrets — the Sparkle
   private key in particular should probably stay local-only rather than
   living in CI secrets, given it's irreplaceable once installed users
   depend on it).

3. **No crash reporting or telemetry.** Only the local, user-toggled
   `DiagnosticLogger` ([DiagnosticLogger.swift](Sources/Yapboard/DiagnosticLogger.swift))
   exists — there's no way to learn about a crash or failure in the field
   unless a user notices and manually sends the log file. Worth
   evaluating a lightweight, privacy-respecting crash reporter now that
   the app has a real distribution path (GitHub Releases + Homebrew)
   beyond just the dev machine.

4. **No automated dependency vulnerability scanning.** `Package.resolved`
   pins exact revisions for `FluidAudio`, `KeyboardShortcuts`, and
   `Sparkle`, but nothing (e.g. Dependabot/Renovate) flags known
   advisories against them. Low effort to add (a `.github/dependabot.yml`
   for the Swift package ecosystem) once GitHub's SPM support for it is
   confirmed adequate.

5. **Sparkle appcast only ever holds one `<item>`.**
   [scripts/release.sh](scripts/release.sh) does `rm -rf "$RELEASE_DIR"`
   before every run, so `generate_appcast` only ever sees the single zip
   just built — no version history, no delta updates, and no persisted
   release-note links across releases. Fine for "latest always replaces,"
   but revisit if staged rollouts or delta updates become worthwhile
   (would mean keeping prior release zips around rather than wiping
   `release/` each time).

## Done

- Reprocess history entries from raw audio. `HistoryStore.updateEntry()`
  overwrites `raw.txt`/`polished.txt` in place (same id/folder/timestamp),
  race-safe against concurrent delete/prune via `entryNoLongerExists`. New
  `AudioDecoder.swift` decodes saved `.m4a`/`.caf` back to 16kHz mono
  Float32 for re-feeding into the ASR model (looped `AVAudioConverter`
  calls so resampling can't silently truncate). Transcribe→vocab-match→
  polish sequence extracted into `TranscriptionPipeline.swift`, shared
  between live recording and reprocessing. `HistoryReprocessor.swift` adds
  guards a live recording doesn't need: refuses to run while a model
  download is in flight (`isModelLoading`), rejects empty/near-empty
  decoded audio before it can blank out a transcript, and refuses to
  overwrite a previously-genuinely-polished transcript with an
  unpolished/empty result (`emptyResult`/polish-downgrade guards) rather
  than silently destroying the only copy. Settings UI: reprocess button
  per History row (hidden when no saved audio), spinner + single-in-flight
  enforcement and error alert state hoisted to `HistorySettingsTab` (not
  row-local, since rows recompute on debounced search). Reviewed by
  `opus-consultant` before merge; findings addressed in a follow-up
  commit. 144 tests pass.

  **Known limitations (not fixed, low severity, flagged in review):** no
  friendly error surfaced if a model preload failed at launch and the
  transcriber was never initialized (reprocess just surfaces the raw
  "not initialized" error rather than a fallback like "record something
  first, or restart") — low priority since this is a rare launch-time
  edge case, not the common path. `updateEntry`'s two-file write
  (`raw.txt`/`polished.txt`) isn't atomic — a failure between the two
  writes (disk full, permissions) can leave the in-memory entry and
  on-disk files briefly mismatched until the next full rescan.

- History storage scale-up, Stage 6 — Sortable folder names. New entries'
  folders are named `<yyyyMMdd-HHmmss>-<uuid>` (via a thread-safe
  `sortableFolderName` helper using `Calendar(identifier: .gregorian)`,
  not `DateFormatter`, since `addEntry` on the main actor and the
  detached scan task can call it concurrently; pinned to Gregorian
  specifically so a non-Gregorian system calendar can't produce
  non-chronological or era-resetting names) so Finder lists history
  chronologically. Legacy bare-UUID folders are migrated during a full
  directory scan, best-effort and idempotently — only when a folder's
  name exactly equals its own entry's UUID (the old default-naming
  pattern), so a user-renamed folder or an already-migrated one is left
  alone; a failed rename just leaves the folder as-is and the entry
  still loads from its original location. Added a `version` field to
  the on-disk `index.json` cache so already-valid Stage 4/5 caches
  (which every existing user already has) get invalidated exactly once,
  forcing the one full scan that performs the migration — without this,
  the fast cache-hit path in `load()` would never call the scan/migration
  code at all and Stage 6 would ship as a no-op for its target users.
  122 tests pass.

  **Known limitation (not fixed, low severity):** if a migrated folder's
  target name happens to already exist on disk (same entry timestamp to
  the second, extremely rare outside a restored backup), the rename is
  skipped and the legacy folder still loads — producing two in-memory
  entries sharing the same `metadata.id`, which SwiftUI `ForEach` and
  `delete(_:)` don't dedupe against. Deferred as pre-existing-class,
  organically triggerable only via backup restore.

- History storage scale-up, Stage 5 — Raise `maxEntries` to 5000. Single
  count-based cap for both transcripts and audio (user explicitly deferred
  a separate audio byte/age budget — revisit later if disk usage becomes a
  concern, mitigated significantly by Stage 1's ~16x size cut). Default is
  configurable via `maxEntriesOverride` init parameter for testability.
  Prune pass now also runs after `load()`'s fast-cache-hit path and after
  the async scan-merge path (not just inside `addEntry`), so a lowered cap
  or an already-over-cap disk state gets pruned properly. Fixed phantom-entry
  bug in `addEntry`'s failure path: folder-write failures now prevent the
  entry from being inserted into `entries`, avoiding an in-memory entry with
  no backing folder that would silently no-op on delete.

- History storage scale-up, Stage 4 — Async startup load + index
  cache. `HistoryStore.load()` now checks a `Recordings`-sibling
  `index.json` (an envelope of `{folderNames, entries}`) against a
  shallow directory listing; if the folder-name sets match, `entries`
  is populated synchronously from the cache with no per-folder disk
  reads. Only on a mismatch (folders added/removed/renamed since the
  cache was written, or a missing/corrupt cache) does it fall back to
  the full per-folder scan, now run off the main thread via
  `Task.detached` and hopped back via `MainActor.run`. Recording the
  full set of *observed* folder names (not just successfully-parsed
  ones) means a single corrupt/legacy folder no longer defeats the
  cache on every future launch. The async fallback merges its results
  into whatever's already in `entries` by `id` (dropping any whose
  folder no longer exists) rather than overwriting outright, so a
  concurrent `addEntry`/`delete` during the scan window can't discard
  real history or resurrect a deleted entry. `addEntry`/`delete`
  persist the index after mutating `entries`. `HistoryEntry` gained
  explicit `CodingKeys` excluding `searchHaystack` (recomputed on
  decode) to keep the cache from duplicating transcript text. 116
  tests pass.

- History storage scale-up, Stage 3 — History UI perf fixes. In
  `SettingsView.swift`: `filteredEntries` now filters on a precomputed
  `searchHaystack` (lowercased `rawTranscript + polishedTranscript`,
  cached on `HistoryEntry` at construction) instead of re-running
  `localizedCaseInsensitiveContains` per keystroke; search is debounced
  ~150ms via `.onChange(of: searchText)`; `selectedEntry` looks up by ID
  against the full `historyStore.entries` instead of re-filtering
  `filteredEntries`, so selection survives the entry being filtered out
  mid-search; `HistoryRow` gates its "reveal in Finder" button on a
  computed `hasAudio` flag (cheap nil-check, not stored — kept
  non-persisted so Stage 4's index cache can't decode it stale) instead
  of calling `audioURL(for:)`'s `fileExists` check on every render. 108
  tests pass.

- History storage scale-up, Stage 2 — Decoupled `HistoryEntry` from
  folder-name-as-ID. Added `folderURL: URL` to `HistoryEntry`;
  authoritative ID is now `metadata.id` (not the folder name), so
  folders no longer need UUID names. `audioURL(for:)` and
  `deleteFolder(for:)` use `entry.folderURL` instead of recomputing
  paths. 108 tests pass.

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
  is kicked off from `YapboardApp.init()` on a background `Task`, disables
  "Start Recording" (menu item + hotkey) via `AppState.isModelLoading`
  until the model finishes loading (or fails, falling back to the existing
  lazy-load-on-first-use path), and surfaces progress via
  `AppState.modelLoadStatus` and a menu bar download icon.
