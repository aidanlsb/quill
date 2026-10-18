# Directory buffer

`quill .` opens the folder as an editable listing. Enter opens the entry under the cursor. `-` opens the parent. Editing a name and pressing `:w` asks before changing the filesystem.

## Sub-features

- `dir-open` lists `notes.md` and `sub/` and arms Enter.
- `dir-enter` opens `notes.md` and shows its body in the text view.
- `dir-parent` returns to the listing with `-`.
- `dir-rename` changes the line to `renamed.md` and `:w` plans a rename behind a confirmation sheet.
- `dir-font` styles that listing with the compact monospace face, not the prose body.

## How to get to it (user POV)

- Run `quill .` or `quill some/dir`, or press `-` from a file. The listing is a compact mono list with a path header, not the centered writing column.
- Move to an entry and press Enter.
- Press `-` to go up.
- Edit the name, then `:w`. A sheet lists the filesystem change. Nothing is renamed until that sheet is confirmed.

## Driving it with verify-quill

Preconditions:

- Doctor printed the release binary.
- The smoke creates its own temporary directory. Do not point it at a folder you care about.

- **Run the smoke.** Run `Scripts/verify-quill --bin "$bin"`. Exit code is 0.
- **Read the directory result.** `artifacts/verify-quill/smoke.log` contains `quill smoke passed`. It does not contain `did not open a directory`, `did not arm Enter`, `listing missing`, `Enter did not`, `minus did not`, `rename left`, `did not ask`, `instead of a rename`, or `directory view font`.
- **Proof.** The log shows the confirmation was requested and a rename was planned. It does not show the temporary file's new name on disk. The smoke deletes that temporary directory when it finishes. The log file remains.

## Gotchas

- The smoke does not click the confirmation button. A passing log is not proof that the file was renamed on disk.
- `notes.md` is near the top of the listing. A `j` that cannot pass line 1 can still reach it, so a directory pass does not prove scrolling.
- If the temporary directory cannot be created, the log starts with `fixture:` and the later directory checks do not run.
