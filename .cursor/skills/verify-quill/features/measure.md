# Measure

The writing view keeps a centered column at the configured measure. Side margins grow on a wider window and stop at the minimum gutter on a narrower one. A directory listing stays full width instead of using that column.

## Sub-features

- `measure-narrow` uses the minimum side gutter and a column narrower than the configured measure when the window is tight.
- `measure-wide` uses the configured measure and equal side margins once the window is wider than that column.
- `measure-stable` keeps the caret at the same place in the window when the width changes, including when live resize ends.
- `directory-resize` keeps the directory inset and widens the listing with the window.

## How to get to it (user POV)

- Open a markdown note. Drag the window wider. The text stays one column and the empty space splits evenly on both sides.
- Drag it narrower than the column plus the minimum gutters. The gutters stop shrinking and the column gets narrower so the text stays on screen.
- Fullscreen, the zoom button, and a split that changes the editor width do the same thing. The caret does not jump.
- Open a folder. The listing runs the width of the window. Resizing keeps that, and does not snap back to the writing column.

## Driving it with verify-quill

Preconditions:

- Doctor printed the release binary.
- No other smoke is using that same log path. Each run overwrites `artifacts/verify-quill/smoke.log`.

- **Run the tests.** `ColumnTests` covers the narrow column, the wide column, and the directory listing as the window resizes. `Scripts/verify-quill --bin "$bin"` runs it, then the launch smoke.
- **Read the measure result.** `artifacts/verify-quill/app-tests.log` shows `ColumnTests` passing. `artifacts/verify-quill/smoke.log` contains `quill smoke passed`. The test log does not contain `column narrow`, `column wide`, `column inset`, `column clip`, `column caret`, or `directory resize`.
- **Proof.** The log file is still at `artifacts/verify-quill/smoke.log` after the process exits.

## Gotchas

- The smoke resizes one window to 640 and 1280 points and reads `textContainerInset`. It does not call `updateInsets` between those widths. A helper that updates the inset inside the check hides this bug.
- It then calls `viewDidEndLiveResize`. That is the fullscreen and split-drag finish path. The smoke does not enter native fullscreen.
- The caret check moves down with `j` before the wide resize. A passing log means the caret's distance from the top of the clip stayed put, not that the document origin was frozen while lines reflowed.
- The directory half of this check toggles the same text view to a listing and resizes again. `directory.md` still covers the listing chrome at one width.
- Linux cannot resize an AppKit window. A green `swift test` does not prove the column follows the window.
