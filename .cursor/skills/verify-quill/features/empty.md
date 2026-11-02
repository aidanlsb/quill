# Empty canvas

A new untitled window, and an empty named file, show a quiet overlay in the writing column: a short rule, a title, and compact keyboard hints. It is not part of the buffer. Finder, Dock, and `quill` with no args all land here; the app does not treat process cwd as a project. Pressing `i` hides the overlay and starts insert on that untitled buffer. Opening a file that has contents takes it down. A directory listing never shows it.

## Sub-features

- `empty-untitled` shows the overlay on an empty untitled buffer in normal mode, with accessibility identifier `quill.emptyCanvas`. The buffer stays empty. Browse root is the last-used folder if it still exists, otherwise home, never `/`.
- `empty-insert` hides the overlay as soon as insert mode starts, even before a character is typed. The text view is not editable until then.
- `empty-escape` brings the overlay back on an still-empty buffer after Escape.
- `empty-type` hides the overlay once the buffer has text, and the storage matches the typed characters. In normal mode, stray keys and `insertText` / paste do not write behind the overlay.
- `empty-file` hides the overlay for a named file with contents, and shows it again for an empty named file using that file's name as the title.
- `empty-directory` keeps the overlay off while a directory buffer is open.
- `empty-minus` from an untitled buffer opens a directory listing at the browse root (last-used or home), not the parent of home and not `/`.
- `empty-sf` / `empty-sg` open the file picker and live grep against that same browse root. The picker panel appears immediately; indexing fills it.
- `empty-edit` `:e notes.md` resolves the relative path against the browse root, not cwd.
- `empty-palette` ⌘K / `search.commands` opens the command palette from the empty window.

## How to get to it (user POV)

- Launch `quill` with no file, or open Quill from Finder or the Dock. The page is not blank: a quiet "Quill" heading and a few keys sit in the writing column, below the caret.
- Press `i`. The hints go away and the insert caret is on an empty untitled page. Other keys in normal mode do not insert.
- Press Escape. The hints return.
- Type a sentence in insert mode. The hints stay gone.
- Press `-`. A directory listing of the last folder you opened, or your home folder, appears. It is never `/`.
- Press Space, then `sf` or `sg`, to find a file or grep in that folder. `:e notes.md` opens a path there. ⌘K lists commands.
- Open an empty `blank.md`. The overlay reads that filename instead of "Quill".
- Open a folder. The overlay is not drawn on the listing.

## Driving it with verify-quill

Preconditions:

- Doctor printed the release binary you are about to run.
- No other smoke is using that same log path. Each run overwrites `artifacts/verify-quill/smoke.log`.

- **Run the tests.** `EmptyStateTests` opens an empty harness, toggles insert, refuses stray inserts, drives `-` / `<leader>sf` / `<leader>sg` / `:e` / the command palette from an untitled model whose last-used folder is `/` (so the fallback is home), and opens a named file and a directory. `Scripts/verify-quill --bin "$bin"` runs it, then the launch smoke.
- **Read the empty result.** `artifacts/verify-quill/app-tests.log` shows `EmptyStateTests` passing. `artifacts/verify-quill/smoke.log` contains `quill smoke passed`. The test log does not contain `empty untitled`, `insert left the canvas`, `typed text left the canvas`, `named file with body`, `empty named file hid`, `directory showed the writing canvas`, `stray keys inserted`, `minus from untitled`, `find files`, `live grep`, or `edit`.
- **Proof.** The log file is still at `artifacts/verify-quill/smoke.log` after the process exits.

## Gotchas

- The overlay is a sibling view on the text view. Clicks pass through it. It must not insert characters or change `h`/`l` indexing. `isEditable` is false in normal mode so NSTextView paste/IME cannot write over the hints.
- Relative launch paths and `:e` resolve against the browse root. `URL(fileURLWithPath:)` on a relative name would have used cwd, which is `/` for a GUI launch.
- Last-used is stored in `state.toml` when a real file or folder is opened, not on empty launch or a keystroke. `BrowseRoot.resolve` stats that path when `-` / the picker / `:e` need it, not on `AppModel` init.
- Linux `swift test` covers `BrowseRoot` and `FileWalk` of `/`. It does not draw the overlay. This host cannot run the smoke if it is not macOS.
