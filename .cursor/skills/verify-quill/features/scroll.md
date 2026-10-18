# Scrolling

Trackpad scrolling moves the document. `j` walks display lines and the viewport follows the caret. `G` and `gg` jump to the ends. Ctrl-d and Ctrl-u move by half the visible window.

## Sub-features

- `scroll-trackpad` moves the clip origin when the document is taller than the window.
- `scroll-j` lands on line 40 after forty `j` motions from the top and moves the clip origin.
- `scroll-wrap` moves `j` to the next screen row of a wrapped paragraph, and `k` back to the start. `$` stays on the first screen row. `g$` reaches the end of the paragraph.
- `scroll-ends` puts `G` near the bottom and `gg` back at the top.
- `scroll-half-page` moves Ctrl-d by the recorded half-page count and Ctrl-u back.

## How to get to it (user POV)

- Open a file longer than the window.
- Scroll with the trackpad or mouse wheel.
- Press `j` until the caret leaves the window. The line under the caret stays visible.
- Press `G`, then `gg`.
- Press Ctrl-d, then Ctrl-u.

## Driving it with verify-quill

Preconditions:

- Doctor printed the release binary.
- The smoke is the drive. Do not send a separate `j` through `osascript`.

- **Run the smoke.** Run `Scripts/verify-quill --bin "$bin"`. Exit code is 0.
- **Read the motion result.** `artifacts/verify-quill/smoke.log` contains `quill smoke passed`. It does not contain `j stopped on line`, `j did not scroll`, `trackpad scroll`, `G left the viewport`, `gg left the viewport`, `Ctrl-d moved`, `Ctrl-u moved`, `wrapped paragraph`, `j left the paragraph`, `j did not advance`, `j jumped`, `k returned`, `screen $`, or `g$`.
- **On failure, read the measurements.** A `FAIL` line includes line, column, cursor, buffer line count, text-view line count, visual line count, document height, clip height, and origin.
- **Proof.** Keep `artifacts/verify-quill/smoke.log`.

## Gotchas

- `j` that stops on line 1 used to leave the origin at 0. Both failures are the same bug. A log that only mentions the origin is incomplete.
- The smoke's `j` goes through `engine.handle`, which is the path `keyDown` uses after it builds a `KeyEvent`. It is not an `NSEvent` posted to the window.
- Linux tests of `j` use logical lines. They stay green when TextKit line lookup is wrong.
- `gg` puts the first line on screen. The clip origin can sit just below the top margin, so it is not required to be 0.
