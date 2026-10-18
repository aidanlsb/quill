---
name: verify-quill
description: "Drive the Quill macOS editor and prove the caret, scrolling, directory buffer, and picker prompt. Use when changing the app target, TextKit layout, vim key handling, oil-style directories, or the Telescope-style picker. The harness is QUILL_SMOKE via Scripts/verify-quill."
---

# Verify Quill

Quill is a native macOS markdown editor (SwiftUI + AppKit + TextKit 2). The user-facing surface is the app window and the `quill` launcher. Linux `swift test` does not compile the app and is not proof that the editor works.

The harness is `Scripts/verify-quill`. It builds or accepts the release binary and runs it with `QUILL_SMOKE=1`. That process drives the caret, scrolling, a real temporary directory, and the file and grep pickers, then exits. It is the same check the macOS CI job runs.

## Launch

From the repo root, on macOS, with Swift 6.2 selected (CI uses Xcode 26.3 at `/Applications/Xcode_26.3.app`; Xcode 16.4 cannot compile this app):

```bash
swift build -c release --product Quill -Xswiftc -strict-concurrency=complete
bin="$(swift build -c release --product Quill -Xswiftc -strict-concurrency=complete --show-bin-path)/Quill"
Scripts/verify-quill --bin "$bin"
```

`Scripts/verify-quill` with no `--bin` runs that build itself, then the smoke.

Ready means the process started by this command has exited 0 and `artifacts/verify-quill/smoke.log` contains the line `quill smoke passed`. A process that is merely alive is not ready: without `QUILL_SMOKE=1` the app stays open, and with it the app exits on purpose.

Smoke starts from `applicationDidFinishLaunching`, not from the window's `onAppear`. Launching the binary from a background shell does not activate the app, so SwiftUI may never show a window and `onAppear` never runs. The main thread then sits in the run loop and prints nothing. `QUILL_SMOKE=1` also activates the app and, at `applicationWillFinishLaunching`, arms a watchdog. If the process has not exited after 20 seconds, the watchdog prints whether launch finished, whether a model was attached, whether `onAppear` ran, whether smoke started, the window count, and the activation policy, then exits 2.

Each invocation is its own process. The directory fixture uses a new temporary directory, so two smokes can run at once. Do not point this at `/Applications/Quill.app` unless that bundle is the binary you just built.

There is no server to keep. Teardown is the process exiting. The app watchdog exits 2 before this script's 30 second kill, so `smoke.log` contains that diagnostic. If the process is still alive after 30 seconds, the script kills that pid and fails.

## Doctor

```bash
Scripts/verify-quill doctor --bin "$bin"
```

Doctor is read-only. It fails when:

- `uname` is not Darwin. The message says this host cannot launch AppKit.
- `swift` is missing, or the binary is missing or not executable.

It prints `swift --version` and the binary path. Run doctor before the first drive, and again after a smoke failure before retrying.

A five-second launch without `QUILL_SMOKE` is a separate check already in `.github/workflows/ci.yml` ("Launch the app"). It only proves the process did not exit. It does not prove the caret, scrolling, or directories.

## Drive

`Scripts/verify-quill` sets `QUILL_SMOKE=1` and runs the binary in the foreground. The smoke builds the same `KeyEvent` values `VimTextView.keyDown` builds and calls `engine.handle`. It does not post OS keyboard events. It does measure the real `NSTextView` caret cell, the clip-view origin, an `AppModel` directory opened from a temporary folder, and the picker query field after `handlePicker`. The directory check also reads that text view's font, insets, and background, so the listing has to be monospaced and wider than the writing column.

One run covers every feature in `features/`. Read the feature file before treating a passing log as proof of that feature. A log that contains `FAIL` is a failure even if you only cared about one feature.

```bash
Scripts/verify-quill --bin "$bin"
```

## Evidence

The proof file is `artifacts/verify-quill/smoke.log` (stdout and stderr of that process). It must contain `quill smoke passed` and must not contain a line starting with `FAIL`.

That log is the action and the result: each failing check names the measurement (caret size, line, cursor, viewport origin, document and clip height, directory listing). A green exit code without that line is not proof.

The smoke does not apply the directory rename to disk. The proof for rename is the confirmation sheet and a planned rename operation, as `features/directory.md` says. Do not claim a file on disk changed unless you observed that file.

Screenshots are not available from this harness. Do not substitute a Linux `swift test` run.

## Cleanup

The script only kills the pid it started. `AppSmoke` deletes its temporary directory. Cleanup must not delete `artifacts/verify-quill/`. After the script returns, `smoke.log` is still at that path.

## Helpers

`Scripts/verify-quill` is the only helper. It is executable.

```bash
Scripts/verify-quill doctor --bin "$bin"
Scripts/verify-quill --bin "$bin"
```

## Maintenance

When the editor's user-facing behavior changes, update this skill with `/maintain-verification-skill`. The feature map is `features/`.
