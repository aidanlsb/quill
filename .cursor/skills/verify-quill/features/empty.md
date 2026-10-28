# Empty canvas

A new untitled window, and an empty named file, show a quiet overlay in the writing column: a short rule, a title, and compact keyboard hints. It is not part of the buffer. Pressing `i`, typing, or opening a file that has contents takes it down. A directory listing never shows it.

## Sub-features

- `empty-untitled` shows the overlay on an empty untitled buffer in normal mode, with accessibility identifier `quill.emptyCanvas`. The buffer stays empty.
- `empty-insert` hides the overlay as soon as insert mode starts, even before a character is typed.
- `empty-escape` brings the overlay back on an still-empty buffer after Escape.
- `empty-type` hides the overlay once the buffer has text, and the storage matches the typed characters.
- `empty-file` hides the overlay for a named file with contents, and shows it again for an empty named file using that file's name as the title.
- `empty-directory` keeps the overlay off while a directory buffer is open.

## How to get to it (user POV)

- Launch `quill` with no file. The page is not blank: a quiet "Quill" heading and a few keys sit in the writing column, below the caret.
- Press `i`. The hints go away and the insert caret is on an empty page.
- Press Escape. The hints return.
- Type a sentence. The hints stay gone.
- Open an empty `blank.md`. The overlay reads that filename instead of "Quill".
- Open a folder. The overlay is not drawn on the listing.

## Driving it with verify-quill

Preconditions:

- Doctor printed the release binary you are about to run.
- No other smoke is using that same log path. Each run overwrites `artifacts/verify-quill/smoke.log`.

- **Run the tests.** `EmptyStateTests` opens an empty harness, toggles insert, types, opens a named file, and opens a directory. `Scripts/verify-quill --bin "$bin"` runs it, then the launch smoke.
- **Read the empty result.** `artifacts/verify-quill/app-tests.log` shows `EmptyStateTests` passing. `artifacts/verify-quill/smoke.log` contains `quill smoke passed`. The test log does not contain `empty untitled`, `insert left the canvas`, `typed text left the canvas`, `named file with body`, `empty named file hid`, or `directory showed the writing canvas`.
- **Proof.** The log file is still at `artifacts/verify-quill/smoke.log` after the process exits.

## Gotchas

- The overlay is a sibling view on the text view. Clicks pass through it. It must not insert characters or change `h`/`l` indexing.
- Linux `swift test` does not draw the overlay. This host cannot run the smoke if it is not macOS.
