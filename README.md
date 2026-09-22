# alauncher

vibe-coded slop speech-to-text + app launcher. minimal, with only the features I need. works fine ¯\_(ツ)\_/¯. Meant to replace Raycast + Handy setup, with their finicky GUI and unintuitive (for me) configs.

Type `emoji` and a name in the launcher to search emoji: Enter types the emoji, ⌘C copies it.

Raycast's window management commands (halves, quarters, thirds, maximize, center, move, next display, restore, fullscreen) are built in: type `window` or the command's name in the launcher to move the window you were in.

Commands in config.toml can be pickers: with `choices = true` a command lists items to pick from in the launcher, for as many rounds as it needs, and `mode = "type"` types the result into the app you were in. `Resources/default-config.toml` describes the protocol.

MIT Licensed. The emoji data comes from Unicode's emoji-test.txt and CLDR, under the Unicode License v3 (`LICENSES/Unicode-3.0.txt`).

If something breaks, see CONTRIBUTING.md
