# Caret

Keystrokes, table formatting, completion, and jumps move the caret through one path. A buffer replacement (open, or a directory refresh) reloads the text view.

The normal-mode cursor is one character cell: the width of the glyph under it, or a space at the end of a line, and the height of that font's em box (`ascender - descender`). It sits on the baseline, with slightly rounded corners and a translucent accent so the glyph stays legible. Insert mode is a 2-pixel rounded beam of the same height that blinks subtly. A heading caret is taller than a body caret. Blank lines and the end of the document use the same em box.

## Sub-features

- `caret-body` draws a block whose width is one body glyph and whose height is the body em box, not the line fragment.
- `caret-heading` uses the heading font's advance and em box.
- `caret-empty` draws the body em box on a blank line, inside that line's glyph bounds.
- `caret-end` draws the em box at the end of the document, on the baseline, inside that line's glyph bounds.
- `caret-beam` draws a 2-pixel rounded beam in insert mode, the same height as the block on that glyph, and blinks only in insert mode.
- `type-scale` uses a 16pt system body, system headings at 1.68 / 1.38 / 1.18 / 1.08 / 1.0 / 1.0 times that body (medium on H1 and H4–H6, semibold on H2/H3), SF Mono for code, and a 1.58 line height. Config `font` names a family and falls back to the system font when it is blank or missing. The default config column is 70. Side and vertical insets stay at least 120pt, and a narrow window still keeps the column inside those gutters.

## How to get to it (user POV)

- Open any markdown file. The window starts in normal mode on the first character.
- Move onto a heading with `j` or by clicking it. The caret grows with the heading.
- Move onto a blank line. The caret stays the body em box.
- Press `i` to enter insert mode. The caret becomes a thin beam and blinks. Press Escape to return to the block; it does not disappear on the way.

## Driving it with verify-quill

Preconditions:

- Doctor printed the release binary you are about to run.
- No other smoke is using that same log path. Each run overwrites `artifacts/verify-quill/smoke.log`.

- **Run the tests.** `CaretTests` and `ThemeTests` in `QuillAppTests` cover the caret cell and the type scale. `Scripts/verify-quill --bin "$bin"` runs them, then the launch smoke.
- **Read the result.** `artifacts/verify-quill/app-tests.log` shows those classes passing. `artifacts/verify-quill/smoke.log` contains `quill smoke passed`. The test log does not contain `body block`, `heading block`, `heading caret`, `empty caret`, `end caret`, `insert beam`, `insert blink`, `normal blink`, `1.3x`, `glyph bounds`, `system caret`, `baseline`, `default body font`, `heading scale`, `heading weight`, `mono font`, `font fallback`, `line height`, or `side gutter`.
- **Proof.** The log file is still at `artifacts/verify-quill/smoke.log` after the process exits.

## Gotchas

- A caret that matches the line-fragment height is the old bug. The smoke fails it with `used the line fragment` and with `1.3x`. TextKit 2's system insertion indicator is that tall rectangle; the smoke fails it with `system caret` when it is still showing.
- The caret rect has to sit inside the line's glyph bounds. The smoke fails that with `glyph bounds` and a miss against the segment baseline with `baseline`.
- Past a trailing newline the caret is on the next line, on that line's baseline. The empty extra line fragment's frame is wrong, so a caret parked on the fragment top fails `end caret` and `baseline`.
- The sample the smoke styles is `iiii`, a blank line, and `Heading` in a larger font, plus the caret past the final newline. Asserting against `maximumAdvancement` does not match this check.
- This host cannot draw the caret if it is not macOS. Doctor fails before a log exists.
- The cell check forces a 20pt body and a 32pt heading so the glyph box stays independent of the 16pt default. `type-scale` reads `QuillTheme.current()` and `QuillConfig.default` without those fixture fonts.
