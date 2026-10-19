# Images

`![alt](path)` stays in the buffer as plain markdown. A preview is drawn directly under that line, inside the writing column, with the picture's aspect ratio and a cap on its height. The preview is not stored in the text, so motions, operators, search, and undo still see only the source. `j` and `k` move from the source line to the next line and back, and the caret does not sit inside the picture. A missing file shows a short placeholder. `images = false` in config, or Toggle Images in the command palette, turns the previews off.

## Sub-features

- `image-local` draws a preview under a path next to the note, wider than a thumbnail and no taller than the column allows.
- `image-missing` draws a placeholder under a path that is not on disk, and does not invent a bitmap.
- `image-text` leaves the buffer equal to the source, with no attachment character.
- `image-motion` steps `j` over the preview onto the next line and `k` back onto the source line. The caret rect stays outside the preview.
- `image-undo` inserts a character and undoes it back to the original source.
- `image-keystroke` types on a line away from the picture without waiting on the decode.
- `image-config` defaults `images` to on, accepts `false`, and rejects a non-boolean.
- `image-command` runs Toggle Images from the command palette.

## How to get to it (user POV)

- Open a markdown file that contains `![diagram](diagram.png)` with the picture beside the file. The picture appears under that line, rounded, within the column. The line of markdown is still there and can be edited.
- Press `j` on that line. The caret moves to the next line, past the picture. Press `k`. It returns to the markdown.
- Point an image at a file that is not there. A quiet placeholder with the alt text sits in the same place.
- Press ⌘K and run Toggle Images. The previews disappear. Run it again and they return.
- Put `images = false` in `config.toml` to start with previews off.

## Driving it with verify-quill

Preconditions:

- Doctor printed the release binary you are about to run.
- No other smoke is using that same log path. Each run overwrites `artifacts/verify-quill/smoke.log`.

- **Run the tests.** `ImageTests` in `QuillAppTests` covers the preview, the placeholder, `j` / `k`, undo, and the config toggle. `Scripts/verify-quill --bin "$bin"` runs them, then the launch smoke.
- **Read the image result.** `artifacts/verify-quill/app-tests.log` shows `ImageTests` passing and a `quill smoke image gap=` line. `artifacts/verify-quill/smoke.log` contains `quill smoke passed`. The test log does not contain `image local`, `image missing`, `image storage`, `image j`, `image k`, `image keystroke`, or `images config`.
- **Proof.** Both logs are still in `artifacts/verify-quill/` after the process exits. `QUILL_PERF=1` also prints `imageIndexMs`, `imageRefreshMs`, `imageKeystrokeMs`, and `imageMotionMs` for a note of 100 images.

## Gotchas

- The preview is screen space under the source line. It is not an `NSTextAttachment`, and the storage string does not grow.
- Decode and network fetches run off the key path. A keystroke on another line does not wait for them.
- Linux `swift test` covers path resolution, the cache, and the screen-row gap. It does not draw the preview. This host cannot run the smoke if it is not macOS.
