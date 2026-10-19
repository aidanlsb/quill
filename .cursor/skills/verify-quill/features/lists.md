# Lists

A bulleted, numbered, or task list stays plain markdown. When a list item wraps, the marker stays at the left of the writing column and the following screen rows start under the first character of the item text. Nested items hang under their own marker. Vim motions still follow the screen rows TextKit drew, and the buffer is not rewritten.

## Sub-features

- `list-hang` aligns the second screen row of `- `, `* `, `+ `, `1. `, and `12. ` with the text after that marker.
- `list-task` does the same for `- [ ] `, `- [x] `, and `- [X] `, so the continuation clears the checkbox.
- `list-nested` hangs a `  - ` item and a `    * ` item under their own text, to the right of a top-level item.
- `list-plain` leaves a wrapped prose line, and a list-shaped line inside a code fence, on the left edge of the column.
- `list-motion` keeps `j` on the next screen row, `0` on that screen row, and `g0` on the marker. The source characters do not change.

## How to get to it (user POV)

- Open a note and type a long `- ` item that wraps inside the column. The bullet stays put. The next screen row starts under the word, not under the bullet.
- The same alignment holds for `* `, `+ `, `1. `, and a task `- [ ] ` or `- [x] `.
- Indent a nested item with spaces. Its wrapped rows line up with that item's text.
- A paragraph that is not a list, and a bullet written inside a code fence, still wrap back to the left edge.
- `j` and `k` move by those screen rows. `0` stays on the screen row. `g0` returns to the marker. The characters in the file are the ones you typed.

## Driving it with verify-quill

Preconditions:

- Doctor printed the release binary you are about to run.
- No other smoke is using that same log path. Each run overwrites `artifacts/verify-quill/smoke.log`.

- **Run the tests.** `ListStyleTests` covers the hanging rows and the screen-line motions. Prefix length, including task boxes and nested markers, runs on Linux in `TokenizerTests.testListHangPrefix`. `Scripts/verify-quill --bin "$bin"` runs `ListStyleTests`, then the launch smoke.
- **Read the list result.** `artifacts/verify-quill/app-tests.log` shows `ListStyleTests` passing. `artifacts/verify-quill/smoke.log` contains `quill smoke passed`. The test log does not contain `list hang` or `list motion`.
- **Proof.** The log file is still at `artifacts/verify-quill/smoke.log` after the process exits.

## Gotchas

- The indent is a paragraph style. It does not insert spaces, and `:TableFormat` is unrelated.
- A bullet inside a code fence is fence text. It does not hang.
- A task checkbox counts only when it is written against the marker (`- [ ] `). A later `[x]` in the sentence does not move the wrap.
- Linux `swift test` checks the prefix length and that a fence has no list marker. It does not draw the rows. This host cannot run the smoke if it is not macOS.
