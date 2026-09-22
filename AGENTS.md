# alauncher

A lean macOS menu-bar agent that replaces two apps for one user:

- **Raycast**: app launcher, script commands and calculator.
- **Handy**: hold-to-talk dictation with LLM cleanup.

It is configured only through text files, so there is no settings UI. The product decisions and measured spike results live in a local `docs/plan.md` that stays out of the repo; read it first if it exists.

## Layout

| Path | What it holds |
|---|---|
| `Package.swift` | The root package, in Swift 5 language mode: the app and its modules. |
| `Sources/alauncher` | Entry point: app mode, CLI subcommands, and the temporary spike harness (`Spike.swift`). |
| `Sources/Core` | Config model, loader and store (TOML via TOMLDecoder), plus `Paths` and `Log`. |
| `Sources/Overlay` | The bottom-of-screen pill and the `TextPanel` popup. AppKit only. |
| `Sources/Dictation` | See below. |
| `Sources/Launcher` | Launcher panel, app and script index, script runner, calculator row, emoji search rows. |
| `Sources/Windows` | Raycast-style window management commands and geometry. |
| `Packages/Calc` | Calculator library. Its contract is `docs/calc-grammar.md`. |
| `Packages/Search` | Fuzzy matcher, zoxide frecency, ranker, Raycast script-header parser, emoji index. Its contract is `docs/search-spec.md`. |
| `Resources` | `Info.plist`, and `default-config.toml`, which documents every config key. |
| `scripts` | Build, sign and one-time signing setup, and the emoji data generator. |

`Sources/Dictation` holds:
- the key monitor (an active `CGEventTap`)
- audio capture (AVAudioEngine)
- Parakeet v2 via FluidAudio
- the cleanup client (OpenAI-compatible)
- the Ask runner (`opencode run`)
- the inserter (types by default; pastes multi-line text)

## Commands

- `just build [debug|release]`: build and sign `build/alauncher.app`.
- `just install`: build, replace `~/Applications/alauncher.app`, and restart it.
- `just test`: run all unit tests (Calc, Search, root).
- `just logs`: follow `~/Library/Logs/alauncher/alauncher.log`.
- `just setup-signing`: one-time. Creates the self-signed identity that keeps macOS permissions across rebuilds.
- `xcrun swift scripts/generate-emoji-data.swift <folder> > Packages/Search/Sources/Search/EmojiData.swift`: regenerates the emoji search data after a macOS update adds emoji. The script's header lists the Unicode and CLDR files `<folder>` must hold.

Swift, the SDK and `codesign` come from Xcode (`xcrun swift`). The Nix dev shell (`direnv allow`) only adds `just`, `jq` and `shellcheck`.

## Runtime files

- **Config:** `~/.config/alauncher/config.toml`, reloaded on save.
- **Secrets:** `~/.config/alauncher/secrets.toml`, mode 0600, never in dotfiles.
- **Data:** `~/Library/Application Support/alauncher`: frecency, dictation history, and the signing keychain password.
- **Caches and logs:** `~/Library/Caches/alauncher` and `~/Library/Logs/alauncher`.
- **Speech model:** `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2`.

## Rules

- **UI:** AppKit only, with no SwiftUI or web views. Keep idle memory low, and never add an unbounded cache.
- **Dependencies:** no new ones without asking the user. The current two are FluidAudio (pinned to a commit) and TOMLDecoder.
- **Privacy:** never log transcripts, answers, clipboard contents or secrets. Log lengths and timings instead.
- **Config keys:** every new key goes in both `Sources/Core/Config.swift` and `Resources/default-config.toml`. A test checks that the two agree.
- **Permissions:** macOS grants Accessibility and Microphone to the signed app. Test keyboard or mic behavior by launching the app with `open`. A binary run from a terminal gets its permissions attributed to the terminal instead.
- **Other apps:** Handy and Raycast may still be running. Don't simulate Right Option or register Cmd+Space while they are.
- **Dictated prompts:** the user often dictates prompts, so expect speech-to-text slips, and read them charitably.
