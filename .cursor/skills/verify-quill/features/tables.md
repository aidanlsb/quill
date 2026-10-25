# Tables

GitHub-flavored markdown tables stay plain text, so vim motions move over the real characters. A table block uses the monospaced face, dims the pipes and the alignment rule, emphasizes the header, and draws a faint background with a header rule and lighter row rules. Nothing draws past the column. A row wider than the column wraps, and a table that cannot line up within the column is shown as typed. `:TableFormat` pads the cells so the pipes line up in the source.

## Sub-features

- `table-detect` finds a header, an alignment row (`:---`, `:---:`, `---:`), and body rows, and ignores a table inside a fence.
- `table-style` paints pipes in the syntax color, the header in semibold mono, body cells in regular mono, a faint background, and underlines for the header rule and row separators.
- `table-align` keeps a right-aligned short cell padded toward its pipe, and sets a positive kern on that pipe when the source is ragged. Compact cells (`|a|b|`) get the same one-space gutters `:TableFormat` writes, so the text lines up, not only the pipes.
- `table-wrap` wraps a row wider than the column onto more screen rows. Its ink stays inside the column.
- `table-fit` pads a table only when its padded width fits the column. A wider table drops the padding and wraps as typed, because padding is extra advance on a single character, which a line cannot break inside. Resizing the window repaints the tables on screen with the new decision.
- `table-command` accepts `:TableFormat`. A config that still sets `formatTablesOnInsertLeave` loads and says the key is ignored. Padding uses display columns, so a wide character and an ASCII cell of the same grapheme count still line up.
- `table-inline` keeps `**bold**`, `*em*`, `` `code` ``, and `[[wikilinks]]` styled inside cells, on the monospaced face so columns stay aligned. `[links](url)` and escaped pipes stay in the cell.
- `table-break` restyles the whole pipe-run when an edit breaks or splits a table, so a header does not keep table paint after the alignment row is gone.
- `table-viewport` leaves a table below the first screen unstyled, then paints it when that screen scrolls into view. Lengthening the widest cell increases the kern on an earlier short cell that is already on screen.

## How to get to it (user POV)

- Open a markdown file that contains a table, including the `| :--- | ---: |` alignment row.
- The header is heavier than the body. Pipes and dashes are quieter than the cell text. Rows sit on a faint band.
- Move with `h` and `l`. The cursor lands on the characters you typed, including the pipes.
- Narrow the window until a wide table no longer fits. Its pipes stop lining up and its rows wrap. The window never scrolls sideways, and `$`, `l`, `j`, and `k` keep the cursor on screen. Widen the window and the table lines up again.
- On a ragged table, type `:TableFormat` and press Enter. The pipes line up and the alignment row keeps its colons. A range (`:%TableFormat`) pads every table in that range. Leaving insert mode does not rewrite the table.

## Driving it with verify-quill

Preconditions:

- Doctor printed the release binary you are about to run.
- No other smoke is using that same log path. Each run overwrites `artifacts/verify-quill/smoke.log`.

- **Run the tests.** `TableStyleTests` covers styling, wrapping, overflow, the viewport, inline cells, and restyle after a table breaks. Detection, padding, gutters, display-width `:TableFormat`, and multi-line recognition run on Linux in `TableTests` and `ExCommandTests.testTableFormatCommand`. `Scripts/verify-quill --bin "$bin"` runs `TableStyleTests`, then the launch smoke.
- **Read the table result.** `artifacts/verify-quill/app-tests.log` shows `TableStyleTests` passing. `artifacts/verify-quill/smoke.log` contains `quill smoke passed`. The test log does not contain `table pipe`, `table header`, `table body`, `table background`, `table rule`, `table rows wrap`, `table row ink`, `overflow`, `table format config`, `table viewport`, `table edit`, `table inline`, `table break`, or `table gutter`.
- **Proof.** The log file is still at `artifacts/verify-quill/smoke.log` after the process exits.

## Gotchas

- The source is not rewritten by styling. Kern only shifts glyphs. `:TableFormat` is what changes the characters.
- A line of dashes without a pipe is not a table. A table inside a code fence is not styled.
- Linux `swift test` covers detection, alignment pads, the padded table width, and `:TableFormat` planning. It does not draw attributes. This host cannot run the smoke if it is not macOS.
- Styling a keystroke uses the lines already cached by the tokenizer. A table that is off screen is parsed when the clip scrolls onto it, not on every character typed in prose. Breaking the alignment row restyles every adjacent pipe line, including rows the caret is not on.
