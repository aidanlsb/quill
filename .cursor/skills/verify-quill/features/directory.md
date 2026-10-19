# Directory buffer

`j` and `k` redraw the old highlight row and the new one. The row style is cached until the listing text, theme, or entries change. Drawing lays out only the fragments that intersect the dirty rect.

`quill .` opens the folder as an editable listing. The listing is a compact monospaced list, left aligned, with a path header and a background tint that is not the writing column. Enter opens the entry under the cursor. `-` opens the parent. Editing a name and pressing `:w` asks before changing the filesystem. Until that write, a rename, a new name, and a deletion stay marked on the listing.

## Sub-features

- `dir-open` lists `notes.md` and `sub/` and binds Enter. In a file, Enter moves down.
- `dir-layout` sets the listing in the compact mono face, in a column wider than the centered prose measure, on a distinct background. Directories are tinted, dotfiles are dimmed, and the header abbreviates home to `~`.
- `dir-enter` opens `notes.md` and shows its body in the text view.
- `dir-parent` returns to the listing with `-`.
- `dir-rename` changes the line to `renamed.md`, marks that line as a rename, and `:w` plans a rename behind a confirmation sheet.
- `dir-pending` marks a synthetic new line and a missing original as a deletion. Those marks are not written into the buffer text.

## How to get to it (user POV)

- Run `quill .` or `quill some/dir`, or press `-` from a file.
- The page is a left-aligned list in a smaller mono face. Folders show a folder icon and a trailing `/`. The path sits in a small header. Your home directory reads as `~`.
- Move to an entry and press Enter.
- Press `-` to go up.
- Edit a name, add a line, or delete one. The row shows `rename`, `new`, `move`, `copy`, or a struck-through `delete` before you write.
- Then `:w`. A sheet lists the filesystem change. Nothing is renamed until that sheet is confirmed.

## Driving it with verify-quill

Preconditions:

- Doctor printed the release binary.
- `DirectoryTests` creates its own temporary directory. Do not point it at a folder you care about.

- **Run the tests.** `DirectoryTests` opens a `TempDirectory`, checks the listing chrome, Enter, parent, and the rename confirmation. `Scripts/verify-quill --bin "$bin"` runs it, then the launch smoke.
- **Read the directory result.** `artifacts/verify-quill/app-tests.log` shows `DirectoryTests` passing. `artifacts/verify-quill/smoke.log` contains `quill smoke passed`. The test log does not contain `did not open a directory`, `did not arm Enter`, `listing missing`, `Enter did not`, `minus did not`, `rename left`, `did not ask`, `instead of a rename`, `directory font`, `directory inset`, `directory column`, `directory background`, `directory header`, `directory accent`, `directory dim`, `was not marked`, or `prose inset`.
- **Proof.** The log shows the confirmation was requested and a rename was planned. It does not show the temporary file's new name on disk. The layout proof is the text view's font and insets while the listing is showing, not a screenshot. `TempDirectory` deletes that directory when the test returns. `app-tests.log` remains.

## Gotchas

- `DirectoryTests` does not click the confirmation button. A passing test is not proof that the file was renamed on disk.
- Icons, the path header, the line highlight, and the pending labels are drawn around the listing. They are not characters in the buffer. A check that the buffer text gained an icon has drifted.
- `notes.md` is near the top of the listing. A `j` that cannot pass line 1 can still reach it, so a directory pass does not prove scrolling.
- If the temporary directory cannot be created, the log starts with `fixture:` and the later directory checks do not run.
- Linux cannot draw this view. A green `swift test` does not prove `dir-layout`.
- Resizing the listing to a second width is `measure.md`. The layout check here is one window size.
