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
- Each run is a new process and a new temporary directory.
- The harness calls `engine.handle` with the same key events as `keyDown`. It does not post OS key events.
- Treat a line starting with `FAIL` as a failed feature. The rest of the log is not a pass for that feature.
- A log that contains `quill smoke watchdog: exiting 2` is a failed launch. Smoke did not finish within 20 seconds.
- Leave `artifacts/verify-quill/smoke.log` in place.

## Proof and skip reporting

- The proof file is `artifacts/verify-quill/smoke.log`.
- It must contain `quill smoke passed`.
- Record which feature file you were checking. A single log can fail one feature and still mention the others.
- Linux cannot run this harness. Report that host as unverified, not as a pass.
- Do not report `swift test` as a substitute for a feature in this map.

## Feature entry contract

Each feature file has an H1, one paragraph, then four H2 sections: `Sub-features`, `How to get to it (user POV)`, `Driving it with verify-quill`, and `Gotchas`.

## Features

- [Caret](caret.md) covers the normal-mode block, the insert-mode beam, and the default 16pt type scale.
- [Scrolling](scroll.md) covers trackpad scrolling and cursor-follow with `j`, `G`, `gg`, and half-page motions.
- [Directory buffer](directory.md) covers opening a folder, Enter, parent, and a rename that asks before writing.
- [Theme](theme.md) covers light, dark, and system, including `:theme` and `<leader>tt`.
- [Performance](perf.md) records launch, editing, and picker timings. It does not assert a speed limit.
