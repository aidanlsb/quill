# Comments

Inline review comments are CriticMarkup in the markdown file. `{>>note<<}` is a standalone comment. `{==passage==}{>>note<<}` anchors a note to a highlight. Both stay on one line. Markers recede like other syntax, the note has a light accent wash, and the passage has a soft underline. There is no sidecar, bubble, or resolved state.

## Sub-features

- `comment-parse` finds `{>>body<<}` and `{==passage==}{>>body<<}` on one line, including nested braces in the body, and ignores unclosed markers, code spans, fences, and frontmatter.
- `comment-style` dims the `{>>` `<<}` `{==` `==}` markers, paints a copper wash on the note, and underlines the passage in both light and dark.
- `comment-add` maps `<leader>c`. In visual mode it wraps the selection as `{==sel==}{>><<}` and inserts inside the note. In normal mode it inserts `{>><<}` at the cursor. A lone `<leader>c` waits because `<leader>cr` and `<leader>ca` are longer.
- `comment-resolve` maps `<leader>cr`. It deletes the `{>>…<<}` and unwraps `{==…==}`, leaving the original text, as one undo. `.` repeats it.
- `comment-jump` maps `]c` and `[c` to the next and previous comment.
- `comment-list` maps `:Comments` to the native picker. Selecting a row jumps to that comment.

## How to get to it (user POV)

- Open a markdown file. Type `{>>too long<<}` or `{==this sentence==}{>>cite the source<<}`.
- The markers fade, the note sits on a light wash, and the passage has a soft underline.
- In visual mode, select a phrase and press Space, then `c`. Wait a beat, or do not type `r` or `a`. Type the note and press Escape.
- Put the cursor on the note and press Space, then `cr`. The markers are gone and the phrase remains.
- Press `]c` and `[c` to move between notes. Type `:Comments` and press Enter, then pick a row.

## Driving it with verify-quill

Preconditions:

- Doctor printed the release binary you are about to run.
- No other smoke is using that same log path. Each run overwrites `artifacts/verify-quill/smoke.log`.

- **Run the tests.** `MarkdownStyleTests` paints the wash and underline. `CommandDispatchTests` runs `<leader>c`, `<leader>cr`, `]c`, `[c`, `:Comments`, undo, and `.`. Parsing, unclosed markers, code spans, fences, nested braces, the leader timeout, and undo run on Linux in `CommentTests` and `CommentCommandTests`. `Scripts/verify-quill --bin "$bin"` runs the AppKit tests, then the launch smoke.
- **Read the comment result.** `artifacts/verify-quill/app-tests.log` shows `MarkdownStyleTests` and `CommandDispatchTests` passing. `artifacts/verify-quill/smoke.log` contains `quill smoke passed`.
- **Proof.** The log file is still at `artifacts/verify-quill/smoke.log` after the process exits.

## Gotchas

- A comment cannot cross a newline. Visual-line over more than one line is refused.
- `<leader>c` does not fire immediately. `<leader>ca` is still code actions. Wait for the timeout, or type another key that is not `r` or `a`.
- Linux `swift test` covers parsing and the engine commands. It does not draw the wash. This host cannot run the smoke if it is not macOS.
