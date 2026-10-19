# Command palette

⌘K opens a command palette on the same native picker as find-files. The query is drawn as you type. Each row is a command name with its shortcut on the right. An empty query lists recently used commands first. Return runs the selected command. Escape closes the palette and puts back the mode and cursor from before it opened. It opens from normal mode and from insert mode.

## Sub-features

- `palette-open` shows the INSERT prompt and the "Command" placeholder.
- `palette-query` shows each typed character in the prompt field.
- `palette-filter` keeps Focus Mode for the query `foc` and selects it.
- `palette-shortcut` draws that command's shortcut, `⌃⌘F`, to the right of the name.
- `palette-run` turns focus mode on and closes the palette.
- `palette-restore` leaves insert mode and the cursor where they were.
- `palette-escape` closes without running a command and leaves normal mode in place.
- `palette-recent` lists Focus Mode first the next time the palette opens.

## How to get to it (user POV)

- In a note, press ⌘K. The palette lists commands, with shortcuts on the right.
- Type `foc`. Focus Mode is the row you can run, and its shortcut reads ⌃⌘F.
- Press Return. The status bar hides and the margins grow.
- Press ⌘K again. Focus Mode is the first row. Press Escape. The caret is where it was, still in insert mode if that is where you started.

## Driving it with verify-quill

Preconditions:

- Doctor printed the release binary you are about to run.
- No other smoke is using that same log path. Each run overwrites `artifacts/verify-quill/smoke.log`.

- **Run the tests.** `PaletteTests` opens the command palette, filters Focus Mode, and runs it. `Scripts/verify-quill --bin "$bin"` runs it, then the launch smoke.
- **Read the palette result.** `artifacts/verify-quill/app-tests.log` shows `PaletteTests` passing. `artifacts/verify-quill/smoke.log` contains `quill smoke passed`. The test log does not contain `palette query`, `palette results`, `palette shortcut`, `palette focus`, `palette escape`, or `palette recent`.
- **Proof.** The log file is still at `artifacts/verify-quill/smoke.log` after the process exits.

## Gotchas

- The smoke calls `presentCommandPalette` and `handlePicker`. It does not post OS keyboard events, so it does not press ⌘K itself. The menu item and the ⌘K shortcut share the command the smoke runs.
- Each row's shortcut is that command's bindings, joined from the same table that runs the key, the leader sequence, and the ex name. Focus Mode is only `⌃⌘F`. A command with a chord and a leader shows both.
- Escape in the command palette closes it. The file and grep pickers still use the first Escape to enter picker normal mode.
- Linux `swift test` covers registry ranking and the enabled predicate. It does not draw the palette. This host cannot run the smoke if it is not macOS.
