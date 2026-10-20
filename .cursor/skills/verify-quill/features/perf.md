# Performance

`QUILL_PERF=1` times launch, a 10k-line edit, file open, motion, the file picker, live grep, and a directory listing. The numbers are the proof. A faster feeling without a smaller number is not.

## Sub-features

- `launch` records milliseconds from process start to `applicationDidFinishLaunching`, to the first key window when one appears, and to the first editable frame (`launchToEditableMs`). That frame has been drawn and has accepted a key. `Scripts/startup-bench.py` repeats the cold launch and `quill <file.md>` and prints medians.
- `style` records a full tokenize of 10k markdown lines and one trailing-character `apply` on the cached lines of that same document.
- `edit` records applying 20 insert keystrokes and 40 `j` motions on a real text view, plus one forced full TextKit layout of that document. An insert restyles the edited lines. Opening the buffer (`textSyncMs`) tokenizes and styles the visible lines, not every line. `j` does not restyle and does not lay out the whole document. A keystroke does not resync the buffer, request hover, or look up a language server.
- `picker` records ignore loading plus the file walk, and the mean of three query keystrokes over 400 names.
- `grep` records one content search of that fixture.
- `directory` records one directory snapshot.
- `file` records reading the 10k-line fixture from disk.
- `imageIndex` records finding 100 `![alt](path)` markers. `imageRefresh` records laying out that note's previews. `imageKeystroke` and `imageMotion` record typing and `j` on it.

## How to get to it (user POV)

- Launch with `quill` or `open -a Quill`. The window should come forward. `QUILL_TRACE=1` prints the same intervals while you work.
- Open a long markdown file, type, and scroll. The trace lines are the keystroke and motion cost.

## Driving it with verify-quill

Preconditions:

- Doctor printed the release binary you are about to run.
- No other perf run is using `artifacts/verify-quill/perf.log`.

- **Run the harness.** `Scripts/verify-quill --bin "$bin"` runs QuillAppTests (unless `QUILL_SKIP_APP_TESTS=1`), the launch smoke, then `QUILL_PERF=1`.
- **Read the numbers.** `artifacts/verify-quill/perf.log` contains `quill perf done` and one `quill perf <name>=<ms>` line for each name in Sub-features. The script prints those lines.
- **Proof.** The log is still at `artifacts/verify-quill/perf.log` after the process exits. Compare `styleEditMs` with `styleFullMs`, and `scrollMs` with `layoutFullMs`. The edit and the motion should be the small ones.

## Gotchas

- This host cannot launch AppKit. The macos job is the only place these numbers exist.
- `layoutFullMs` is one walk of every TextKit fragment. `scrollMs` is one `j`. They are different operations; the point of printing both is that a motion used to pay the full walk.
- `textSyncMs` is the visible-range style of a buffer that was just assigned. It is not a full-document restyle. `keystrokeMs` is one insert at the start of that same view.
- `ignoreWalkAllMs` visits every file, which is what ignore loading used to do. `pickerOpenMs` is the load that skips ignored directories.
- A five-second launch without `QUILL_PERF` does not produce this log.
