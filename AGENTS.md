# Agent notes

Linux `swift test` passing is not done. The macOS build and the verify-quill smoke must pass before a change is finished.

| Rule | What enforces it |
|---|---|
| Linux green is not done; macOS build + verify-quill smoke must pass | `.github/workflows/ci.yml` job `macos` builds with `-strict-concurrency=complete`, runs `swift test` (including `QuillAppTests`), and runs `Scripts/verify-quill` (the launch smoke). The recipe is `.cursor/skills/verify-quill/`. |
| Wire editor views only through `VimTextView.host(engine:frame:)` | `Scripts/check_boundaries.py` rejects `VimTextView.make(` / `.commonInit()` outside `VimTextView.swift`. |
| No nonisolated mutable static | `Scripts/check-concurrency-fixture.sh` typechecks the historical `AppSmoke.started` and requires the Swift 6 error. The macos job also passes `-strict-concurrency=complete` to `swift test` and `swift build`. |
| `nonisolated(unsafe)` and `@unchecked Sendable` need a reason | `python3 Scripts/check_boundaries.py --self-test` requires `// quill-concurrency:` within the previous 8 lines. |
| Do not force-unwrap `NSApp` before launch | The same check rejects bare `NSApp`. Use `NSApp?` or `NSApplication.shared`. |
| Scripts run on bash 3.2 | The same check rejects an unguarded `${name[@]}`. The macos job executes `Scripts/quill` under `/bin/bash`. The linux job runs `shellcheck -s bash`. |

When a rule is already in this table and nothing fails if an agent skips it, fix the enforcer in the same change. Branch protection is not set from this repo's automation token. A repo admin has to mark the `macos` check required.
