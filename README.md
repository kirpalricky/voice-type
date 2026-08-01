# VoiceType

A macOS menu bar app for hotkey-triggered voice dictation: hold a shortcut, speak, and get transcribed (and optionally AI-polished) text inserted wherever your cursor is.

## Features

- **On-device transcription** using [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet ASR) — no audio leaves your machine
- **Optional AI polishing** of raw transcripts via Apple's on-device Foundation Models (macOS 15+ with Apple Intelligence)
- **Global hotkey** recording, configurable via [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
- **Vocabulary matching** to bias transcription toward custom terms/names
- **History browser** with search — past recordings and transcripts are saved locally (audio pruned after 5,000 entries)
- **Auto-updates** via [Sparkle](https://github.com/sparkle-project/Sparkle)

## Requirements

- macOS 14+
- Xcode 16 / Swift 6 toolchain to build

## Building

```bash
swift build
swift test
```

## Running the packaged app

```bash
./package_app.sh
```

Produces a signed (ad-hoc) `.app` bundle. VoiceType is **not notarized** (no Apple Developer Program membership), so Gatekeeper will block first launch — see [docs/RELEASE_SETUP.md](docs/RELEASE_SETUP.md) for the standard workarounds (System Settings > Privacy & Security > Open Anyway, or `xattr -d com.apple.quarantine`).

## Installing via Homebrew

```bash
brew install kirpalricky/voicetype/voicetype
```

Tap: [homebrew-voicetype](https://github.com/kirpalricky/homebrew-voicetype)

## Releasing

See [docs/RELEASE_SETUP.md](docs/RELEASE_SETUP.md) for the full Sparkle key setup and release-cutting process (`scripts/release.sh`).

## Project layout

- `Sources/VoiceType/` — app source (audio capture, transcription pipeline, hotkeys, settings, history, menu bar UI)
- `Tests/VoiceTypeTests/` — test suite
- `scripts/` — release automation
- `docs/` — release and setup documentation
- `BACKLOG.md` — open work items, stack ranked

## Contributing

See [CLAUDE.md](CLAUDE.md) for the agent-assisted development workflow used in this repo.

## License

[GPL-3.0](LICENSE)
