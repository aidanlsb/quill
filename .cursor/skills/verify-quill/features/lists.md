# Lists

A bulleted, numbered, or task list stays plain markdown. List items sit in a gutter to the right of body paragraphs, with a heavier accent-colored marker and a little space after each item. When a list item wraps, the marker stays in that gutter and the following screen rows start under the first character of the item text. Nested items hang under their own marker. Vim motions still follow the screen rows TextKit drew, and the buffer is not rewritten.

## Sub-features

- `list-hang` aligns the second screen row of `- `, `* `, `+ `, `1. `, and `12. ` with the text after that marker.
- `list-task` does the same for `- [ ] `, `- [x] `, and `- [X] `, so the continuation clears the checkbox.
- `list-nested` hangs a `  - ` item and a `    * ` item under their own text, to the right of a top-level item.
- `list-plain` leaves a wrapped prose line, and a list-shaped line inside a code fence, on the left edge of the column.
- `list-motion` keeps `j` on the next screen row, `0` on that screen row, and `g0` on the marker. `h` and `l` still step across the typed `-` and the space after it. The source characters do not change.
- `list-style` insets every list item (`firstLineHeadIndent` plus a matching hanging `headIndent`), paints the marker and checkbox in the list accent at medium weight, and adds a little paragraph spacing. Light and dark both keep that contrast. Single-line items get the same gutter and marker as wrapped ones.

## How to get to it (user POV)

- Open a note and type `- item`. The bullet sits in from the left of the writing column, in a crisper accent color, and is clearly not a body paragraph.
- Type a long `- ` item that wraps inside the column. The bullet stays in that gutter. The next screen row starts under the word, not under the bullet.
- The same alignment holds for `* `, `+ `, `1. `, and a task `- [ ] ` or `- [x] `.
- Indent a nested item with spaces. Its wrapped rows line up with that item's text, further right than a top-level item.
- A paragraph that is not a list, and a bullet written inside a code fence, still wrap back to the left edge.
- `j` and `k` move by those screen rows. `0` stays on the screen row. `g0` returns to the marker. The characters in the file are the ones you typed.

## Driving it with verify-quill

Preconditions:

- Doctor printed the release binary you are about to run.
- No other smoke is using that same log path. Each run overwrites `artifacts/verify-quill/smoke.log`.

- **Run the tests.** `ListStyleTests` covers the hanging rows, the gutter and marker attributes, and the screen-line motions. Prefix length, including task boxes and nested markers, and the list token style map, run on Linux in `TokenizerTests.testListHangPrefix` and `TokenizerTests.testTokens`. `Scripts/verify-quill --bin "$bin"` runs `ListStyleTests`, then the launch smoke.
- **Read the list result.** `artifacts/verify-quill/app-tests.log` shows `ListStyleTests` passing. `artifacts/verify-quill/smoke.log` contains `quill smoke passed`. The test log does not contain `list hang`, `list motion`, or `list style`.
- **Proof.** The log file is still at `artifacts/verify-quill/smoke.log` after the process exits.

## Gotchas

- The indent is a paragraph style. It does not insert spaces, and `:TableFormat` is unrelated. Nested levels still come from the spaces or tabs in the file; the gutter is added in front of those.
- A bullet inside a code fence is fence text. It does not hang or take the list accent.
- A task checkbox counts only when it is written against the marker (`- [ ] `). A later `[x]` in the sentence does not move the wrap.
- Linux `swift test` checks the prefix length, the token style map, and that a fence has no list marker. It does not draw the rows. This host cannot run the smoke if it is not macOS.
