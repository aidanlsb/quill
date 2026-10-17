# Caret

The normal-mode cursor is one character cell of the font on that glyph. Insert mode is a one-point beam of the same height. A heading caret is taller than a body caret.

## Sub-features

- `caret-body` draws a block whose width is one body glyph and whose height is the body em box, not the line fragment.
- `caret-heading` uses the heading font's advance and em box.
- `caret-beam` draws a one-point beam in insert mode.

## How to get to it (user POV)

- Open any markdown file. The window starts in normal mode on the first character.
- Move onto a heading with `j` or by clicking it.
- Press `i` to enter insert mode. Press Escape to return to the block.

## Driving it with verify-quill

Preconditions:

- Doctor printed the release binary you are about to run.
- No other smoke is using that same log path. Each run overwrites `artifacts/verify-quill/smoke.log`.

- **Run the smoke.** Run `Scripts/verify-quill --bin "$bin"`. The process exits 0.
- **Read the caret result.** Open `artifacts/verify-quill/smoke.log`. It contains `quill smoke passed`. It does not contain `body block`, `heading block`, `heading caret`, or `insert beam`.
- **Proof.** The log file is still at `artifacts/verify-quill/smoke.log` after the process exits.

## Gotchas

- A caret that matches the line-fragment height is the old bug. The smoke fails it with `used the line fragment`.
- The sample the smoke styles is `iiii` in the body font and `Heading` in a larger font. Asserting against `maximumAdvancement` does not match this check.
- This host cannot draw the caret if it is not macOS. Doctor fails before a log exists.
