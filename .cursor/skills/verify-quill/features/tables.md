# Tables

GitHub-flavored markdown tables stay plain text, so vim motions move over the real characters. A table block uses the monospaced face, dims the pipes and the alignment rule, emphasizes the header, and draws a faint background with a header rule and lighter row rules. Wide rows clip instead of wrapping. `:TableFormat` pads the cells so the pipes line up in the source.

## Sub-features

- `table-detect` finds a header, an alignment row (`:---`, `:---:`, `---:`), and body rows, and ignores a table inside a fence.
- `table-style` paints pipes in the syntax color, the header in semibold mono, body cells in regular mono, a faint background, and underlines for the header rule and row separators.
- `table-align` keeps a right-aligned short cell padded toward its pipe, and sets a positive kern on that pipe when the source is ragged.
- `table-nowrap` uses clipping line breaks. A row wider than the column stays one visual line.
- `table-command` accepts `:TableFormat`. `formatTablesOnInsertLeave` defaults off and accepts `true`.
- `table-viewport` leaves a table below the first screen unstyled, then paints it when that screen scrolls into view. Editing a later cell increases the kern on an earlier short cell.

## How to get to it (user POV)

- Open a markdown file that contains a table, including the `| :--- | ---: |` alignment row.
- The header is heavier than the body. Pipes and dashes are quieter than the cell text. Rows sit on a faint band.
- Move with `h` and `l`. The cursor lands on the characters you typed, including the pipes.
- On a ragged table, type `:TableFormat` and press Enter. The pipes line up and the alignment row keeps its colons.
- Set `formatTablesOnInsertLeave = true` in `config.toml` when leaving insert mode should pad the table under the cursor.

## Driving it with verify-quill

Preconditions:

- Doctor printed the release binary you are about to run.
- No other smoke is using that same log path. Each run overwrites `artifacts/verify-quill/smoke.log`.

- **Run the smoke.** Run `Scripts/verify-quill --bin "$bin"`. The process exits 0.
- **Read the table result.** Open `artifacts/verify-quill/smoke.log`. It contains `quill smoke passed`. It does not contain `table detect`, `table align`, `table pipe`, `table header`, `table body`, `table background`, `table rule`, `table nowrap`, `table command`, `table format config`, `table viewport`, or `table edit`.
- **Proof.** The log file is still at `artifacts/verify-quill/smoke.log` after the process exits.

## Gotchas

- The source is not rewritten by styling. Kern only shifts glyphs. `:TableFormat` is what changes the characters.
- A line of dashes without a pipe is not a table. A table inside a code fence is not styled.
- Linux `swift test` covers detection, alignment pads, and `:TableFormat` planning. It does not draw attributes. This host cannot run the smoke if it is not macOS.
- Styling a keystroke uses the lines already cached by the tokenizer. A table that is off screen is parsed when the clip scrolls onto it, not on every character typed in prose.
