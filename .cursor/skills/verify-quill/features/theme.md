# Theme

The editor can follow the macOS appearance or stay light or dark. `:theme` toggles the explicit sides. `<leader>tt` does the same toggle. The last runtime choice is what the next launch uses.

## Sub-features

- `theme-dark` draws a darker background than the light scheme.
- `theme-command` accepts `:theme dark`. `:theme` with no argument toggles. An unknown name is rejected.
- `theme-leader` maps `<leader>tt` to the toggle. A lone `<leader>t` is only a prefix.
- `theme-memory` writes the choice to `state.toml` and reads it back.
- `theme-config` defaults to `system` and accepts `theme = "dark"` in `config.toml`.

## How to get to it (user POV)

- Open any file. The colors follow the config `theme` value, or `state.toml` if a toggle was used before.
- Type `:theme dark` and press Enter. The page goes dark.
- Type `:theme` and press Enter. The page goes light.
- Press Space, then `tt`. The page switches again.
- Choose View → Toggle Light/Dark, or press Shift-Command-L.
- Quit and reopen. The last choice is still in effect.

## Driving it with verify-quill

Preconditions:

- Doctor printed the release binary you are about to run.
- No other smoke is using that same log path. Each run overwrites `artifacts/verify-quill/smoke.log`.

- **Run the smoke.** Run `Scripts/verify-quill --bin "$bin"`. The process exits 0.
- **Read the theme result.** Open `artifacts/verify-quill/smoke.log`. It contains `quill smoke passed`. It does not contain `theme dark`, `theme command`, `theme toggle`, `theme name`, `leader tt`, `theme memory`, or `theme config`.
- **Proof.** The log file is still at `artifacts/verify-quill/smoke.log` after the process exits.

## Gotchas

- The smoke writes `state.toml` under a temporary directory. It does not change `~/.config/quill/state.toml`.
- `theme = "system"` still follows the Mac appearance. The smoke compares explicit light and dark backgrounds, not the system setting.
- Linux `swift test` covers the command, the leader prefix, and the toggle rule. It does not draw the colors. This host cannot run the smoke if it is not macOS.
