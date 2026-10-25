# Quill verification map

This directory is the maintained source for verifying Quill's user-facing editor behavior. Read the index, then use the matching feature file.

## Baseline preconditions

- macOS with Swift 6.2. CI selects `/Applications/Xcode_26.3.app`. Xcode 16.4 does not compile the app.
- Repo root as the working directory.
- A release binary built with `-Xswiftc -strict-concurrency=complete`.
- `Scripts/verify-quill doctor --bin "$bin"` prints that binary path.
- Drive only a process this run started. Do not drive the user's installed `/Applications/Quill.app`.

## Driving conventions

- One command covers the map: `Scripts/verify-quill --bin "$bin"`.
- `QuillAppTests` sends `NSEvent`s through `keyDown`. It does not post OS key events. Each feature names its test class below.
- The launch process is separate. A line starting with `FAIL` in `smoke.log`, or an XCTest failure in `app-tests.log`, fails that feature.
- A log that contains `quill smoke watchdog: exiting 2` is a failed launch. Smoke did not finish within 20 seconds.
- Leave `artifacts/verify-quill/` in place.

## Proof and skip reporting

- Proof is `artifacts/verify-quill/app-tests.log` (XCTest for that feature's class) and `artifacts/verify-quill/smoke.log`.
- `smoke.log` must contain `quill smoke passed`.
- Record which feature file you were checking. A single log can fail one feature and still mention the others.
- Linux cannot run this harness. Report that host as unverified, not as a pass.
- Do not report `swift test` as a substitute for a feature in this map.

## Feature entry contract

Each feature file has an H1, one paragraph, then four H2 sections: `Sub-features`, `How to get to it (user POV)`, `Driving it with verify-quill`, and `Gotchas`.

## Features

- [Caret](caret.md) covers the normal-mode block, the insert-mode beam, and the default 16pt type scale.
- [Measure](measure.md) covers the centered writing column and the full-width directory listing as the window resizes.
- [Scrolling](scroll.md) covers trackpad scrolling and cursor-follow with `j`, `G`, `gg`, and half-page motions.
- [Directory buffer](directory.md) covers opening a folder, the mono listing layout, Enter, parent, and a rename that asks before writing.
- [Theme](theme.md) covers light, dark, and system, including `:theme` and `<leader>tt`.
- [Tables](tables.md) covers GFM table styling, alignment, wrapping within the column, and `:TableFormat`.
- [Lists](lists.md) covers hanging indents, the list gutter, and marker styling for bullets, numbers, and task items.
- [Images](images.md) covers inline `![alt](path)` previews under the source line.
- [Performance](perf.md) records launch, editing, and picker timings. It does not assert a speed limit.
- [Picker](picker.md) covers the `<leader>sf` and `<leader>sg` prompt, caret, placeholder, and live filtering.
- [Command palette](palette.md) covers ⌘K, the visible query, right-aligned shortcuts, running a command, and Escape restoring the previous mode.
