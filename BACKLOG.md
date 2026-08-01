# Backlog

## Open (stack ranked)

1. **Sparkle appcast only ever holds one `<item>`.**
   [scripts/release.sh](scripts/release.sh) does `rm -rf "$RELEASE_DIR"`
   before every run, so `generate_appcast` only ever sees the single zip
   just built — no version history, no delta updates, and no persisted
   release-note links across releases. Fine for "latest always replaces,"
   but revisit if staged rollouts or delta updates become worthwhile
   (would mean keeping prior release zips around rather than wiping
   `release/` each time).

## Done

- Crash reporting & non-fatal error telemetry via `sentry-cocoa` →
  hosted GlitchTip (two projects, `yapboard-crashes`/`yapboard-errors`,
  separate DSNs against a shared 1000-events/month free-tier cap).
  Configured deny-most: no session tracking, no perf/profiling traces, no
  default PII, no screenshots/view-hierarchy, no file-IO/user-interaction
  tracing; `beforeSend`/`beforeBreadcrumb` redact `/Users/<name>/` paths
  and gate on a three-state consent (`unset`/`enabled`/`disabled`) via a
  holding-pen pattern, since the crash handler installs before the app
  can ask permission. Consent is asked once — on the first crash
  (`SentrySDK.crashedLastRun`) or first non-fatal error, whichever comes
  first — surfaced immediately at launch or mid-session, with a manual
  override in About > Diagnostics
  ([SettingsView.swift](Sources/Yapboard/SettingsView.swift)). Existing
  `os_log(.error, ...)` sites now also feed a new `ErrorReporter`
  ([ErrorReporter.swift](Sources/Yapboard/ErrorReporter.swift)), which
  tallies by `(site, domain, code)` and flushes once per session as a
  single batched event — not one send per error — to stay well under
  quota. `Transcriber`'s error path is deliberately sanitized before
  reporting since the underlying error can otherwise carry transcribed
  speech text. App-specific scope context (pipeline stage, permission
  state, model load state, history size, memory footprint) is attached
  via `SentrySDK.configureScope`
  ([CrashContext.swift](Sources/Yapboard/CrashContext.swift)) —
  explicitly excluding transcript text, glossary contents, and any
  hardware-derived identifiers. `scripts/release.sh` now verifies a
  `.dSYM` is produced and archives the shipped (post-signing) binary +
  dSYM per version under `./release-symbols/`, cross-checking their
  UUIDs match, since none of this is useful without preserved symbols.
  Reviewed by `opus-consultant` before merge; addressed all must-fix
  findings (a transcript-content leak via `TranscriberError`'s rethrow,
  non-fatal errors never triggering the consent ask, the dialog being
  gated behind menu-bar interaction instead of firing at launch, a
  release-script re-run corrupting the symbol archive via nested `cp
  -R`, and a gitignored `Secrets.swift` breaking CI) plus several
  should-fix items (the dual-DSN wiring itself, a pinned SDK version,
  the Settings toggle replaying held events instead of stranding them).
  173 tests pass.

  **Known limitation, not yet resolved:** whether GlitchTip's hosted
  free tier actually symbolicates native Apple crashes (it may lack
  Sentry's separate `symbolicator` service) is unverified — the spike
  requires shipping one deliberate crash from a real release build,
  deferred pending confirmation since it touches the live
  release/publish pipeline (`gh release create`/`upload`) rather than
  something safely reversible.

- Added automated dependency vulnerability scanning via
  [.github/dependabot.yml](.github/dependabot.yml). Confirmed GitHub's
  `swift` package-ecosystem support covers `Package.resolved` (pins for
  `FluidAudio`, `KeyboardShortcuts`, `Sparkle`) — weekly update checks,
  plus a second `github-actions` entry to keep `ci.yml`'s action versions
  patched too.

- Cut the first real release (v1.2.0) and fixed the Homebrew cask's
  `sha256 :no_check` placeholder with the real digest
  ([homebrew-yapboard@4095b01](https://github.com/kirpalricky/homebrew-yapboard/commit/4095b01)).
  Considered a `workflow_dispatch` CI pipeline for `scripts/release.sh`
  first (former backlog #2) but decided against it: the app is ad-hoc
  signed with no Developer ID, so the Sparkle EdDSA private key is the
  *only* trust anchor, and Sparkle's own client code refuses to accept
  an EdDSA key rotation without a Developer-ID-signed update — meaning a
  leaked key has no recovery path at all today. Storing that key as a CI
  secret (even gated behind a required-reviewer GitHub Environment) was
  judged not worth the added exposure until Developer ID signing +
  notarization exists to make the key rotatable. Releases stay local-only
  for now; revisit CI once notarization lands.

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
