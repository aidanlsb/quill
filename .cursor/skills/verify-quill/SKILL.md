---
name: verify-quill
description: "Drive the Quill macOS editor and prove the caret, scrolling, directory buffer, picker prompt, command palette, and markdown tables. Use when changing the app target, TextKit layout, vim key handling, oil-style directories, the Telescope-style picker, the command palette, or markdown table styling. The harness is QuillAppTests plus the QUILL_SMOKE launch check, via Scripts/verify-quill."
---

# Verify Quill

Quill is a native macOS markdown editor (SwiftUI + AppKit + TextKit 2). The user-facing surface is the app window and the `quill` launcher. Linux `swift test` does not compile the app and is not proof that the editor works.

The harness is `Scripts/verify-quill`. It runs `swift test --filter QuillAppTests` (unless `--bin` is set and `QUILL_SKIP_APP_TESTS=1`), then launches the release binary with `QUILL_SMOKE=1`. QuillAppTests drives the caret, scrolling, a real temporary directory, the file and grep pickers, and markdown table styling through `keyDown`. The launch smoke checks that the app comes up, the editor is wired, one keystroke changes the buffer, and a resize does not crash. CI runs the tests in its `swift test` step and the launch smoke with `QUILL_SKIP_APP_TESTS=1`.

## Launch

From the repo root, on macOS, with Swift 6.2 selected (CI uses Xcode 26.3 at `/Applications/Xcode_26.3.app`; Xcode 16.4 cannot compile this app):

```bash
swift build -c release --product Quill -Xswiftc -strict-concurrency=complete
bin="$(swift build -c release --product Quill -Xswiftc -strict-concurrency=complete --show-bin-path)/Quill"
Scripts/verify-quill --bin "$bin"
```

`Scripts/verify-quill` with no `--bin` runs that build itself, then the smoke.

Ready means QuillAppTests passed (when not skipped) and the launch process has exited 0 with `quill smoke passed` in `artifacts/verify-quill/smoke.log`. A process that is merely alive is not ready: without `QUILL_SMOKE=1` the app stays open, and with it the app exits on purpose. Test output is `artifacts/verify-quill/app-tests.log`.

Smoke starts from `applicationDidFinishLaunching`, not from the window's `onAppear`. Launching the binary from a background shell does not activate the app, so SwiftUI may never show a window and `onAppear` never runs. The main thread then sits in the run loop and prints nothing. `QUILL_SMOKE=1` also activates the app and, at `applicationWillFinishLaunching`, arms a watchdog. If the process has not exited after 20 seconds, the watchdog prints whether launch finished, whether a model was attached, whether `onAppear` ran, whether smoke started, the window count, and the activation policy, then exits 2.

Each invocation is its own process. The directory fixture uses a new temporary directory, so two smokes can run at once. Do not point this at `/Applications/Quill.app` unless that bundle is the binary you just built.

There is no server to keep. Teardown is the process exiting. The app watchdog exits 2 before this script's 30 second kill, so `smoke.log` contains that diagnostic. If the process is still alive after 30 seconds, the script kills that pid and fails.

After a passing smoke, the script runs a second process with `QUILL_PERF=1`. That process prints `quill perf <name>=<milliseconds>` lines and `quill perf done`, then exits. The log is `artifacts/verify-quill/perf.log`. It is a measurement, not a behavior pass: a missing `quill perf done` fails the script. `features/perf.md` names each number.

The regression gate is a separate process, `QUILL_BENCH=1`, driven by `Scripts/bench.sh`. Smoke still owns `QUILL_PERF`. The gate compares a pull request to its base commit on the same Mac. `CONTRIBUTING.md` says how to run it locally, including on Aidan's Mac.

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

`QuillAppTests` builds real `NSEvent`s and calls `VimTextView.keyDown`. It does not post OS keyboard events. One `XCTestCase` covers each feature in `features/`. The launch smoke then checks the running app. Read the feature file before treating a passing log as proof of that feature. An XCTest failure, or a launch log that contains `FAIL`, is a failure even if you only cared about one feature.

```bash
Scripts/verify-quill --bin "$bin"
```

## Evidence

Two proof files:

- `artifacts/verify-quill/app-tests.log` is the XCTest run for `QuillAppTests` (omitted when `QUILL_SKIP_APP_TESTS=1`). A pass is `QuillAppTests passed` from the script, or a green `swift test --filter` for the class named in the feature file.
- `artifacts/verify-quill/smoke.log` is the launch process. It must contain `quill smoke passed` and must not contain a line starting with `FAIL`.

A failing XCTest names the measurement (caret size, line, cursor, viewport origin, document and clip height, column inset, directory listing, picker query) in the assertion. A green exit code without `quill smoke passed` is not proof of launch.

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
