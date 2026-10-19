# Picker

`<leader>sf` opens a fuzzy file picker. `<leader>sg` opens live grep. Both use the same prompt: the query is drawn as you type, insert mode shows a caret, and an empty query shows a placeholder. Results narrow to the query. Matched characters are stronger than the rest of the row, and the selected row carries a quiet wash. The prompt names INSERT or NORMAL.

## Sub-features

- `picker-query` shows each typed character in the prompt field.
- `picker-placeholder` shows "File name" or "Pattern" while the query is empty.
- `picker-caret` draws a one-point caret in insert mode and removes it in normal mode.
- `picker-filter` keeps `notes.md` and drops `ideas.md` for the query `no`.
- `picker-highlight` paints the matched characters in the text color and the rest dimmer.
- `picker-mode` reads INSERT, then NORMAL after Escape.
- `picker-grep` shows the query `alpha` and a `notes.md` hit, not `ideas.md`.

## How to get to it (user POV)

- Open a folder of markdown files.
- Press Space, then `sf`. The prompt says INSERT and "File name".
- Type a file name. The prompt shows those characters and the list narrows.
- Press Escape. The prompt says NORMAL and the caret is gone. Press `q` to close.
- Press Space, then `sg`. Type a word from a file. Matching lines appear as `file:line`.

## Driving it with verify-quill

Preconditions:

- Doctor printed the release binary you are about to run.
- No other smoke is using that same log path. Each run overwrites `artifacts/verify-quill/smoke.log`.

- **Run the tests.** `PickerTests` types into the file picker and waits on `picker.items` for grep. `Scripts/verify-quill --bin "$bin"` runs it, then the launch smoke.
- **Read the picker result.** `artifacts/verify-quill/app-tests.log` shows `PickerTests` passing. `artifacts/verify-quill/smoke.log` contains `quill smoke passed`. The test log does not contain `picker query`, `picker placeholder`, `picker caret`, `picker filter`, `picker highlight`, `picker mode`, `grep query`, `grep results`, or `grep highlight`.
- **Proof.** The log file is still at `artifacts/verify-quill/smoke.log` after the process exits.

## Gotchas

- The smoke calls `handlePicker` with the same key values the picker key view builds. It does not post OS keyboard events.
- The fixture is a temporary directory with `notes.md` (`alpha notes`) and `ideas.md` (`beta ideas`). It does not index the home folder.
- Grep is debounced. The check waits until `picker.items` changes and the query field reads `alpha`.
- Linux `swift test` covers picker key handling and highlight ranges. It does not draw the field. This host cannot run the smoke if it is not macOS.
