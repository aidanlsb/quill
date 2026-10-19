# Agent notes

Linux `swift test` passing is not done. The macOS build and the verify-quill smoke must pass before a change is finished.

Quill is fast, simple, and keyboard driven. Its only job is a great markdown editing experience: long-form prose, headings, lists, tables, links, and code blocks. Weight changes and benchmarks toward that, and keep the implementation small enough to read.

| Rule | What enforces it |
|---|---|
| Linux green is not done; macOS build + verify-quill smoke must pass | `.github/workflows/ci.yml` job `macos` builds with `-strict-concurrency=complete` and runs `Scripts/verify-quill`. The recipe is `.cursor/skills/verify-quill/`. |
| No nonisolated mutable static | `Scripts/check-concurrency-fixture.sh` typechecks the historical `AppSmoke.started` and requires the Swift 6 error. The macos job also passes `-strict-concurrency=complete` to `swift test` and `swift build`. |
| `nonisolated(unsafe)` and `@unchecked Sendable` need a reason | `python3 Scripts/check_boundaries.py --self-test` requires `// quill-concurrency:` within the previous 8 lines. |
| Do not force-unwrap `NSApp` before launch | The same check rejects bare `NSApp`. Use `NSApp?` or `NSApplication.shared`. |
| Scripts run on bash 3.2 | The same check rejects an unguarded `${name[@]}`. The macos job executes `Scripts/quill` under `/bin/bash`. The linux job runs `shellcheck -s bash`. |
| Every change passes the perf gate, and the PR description includes the bench diff | The `macos` job runs `Scripts/bench.sh ci` on pull requests. It builds the PR and the base commit on the same runner; `Scripts/bench_compare.py` fails the job when a metric regresses past its ratio and floor. The job writes the table to the step summary and updates a PR comment marked `<!-- quill-bench -->`. Copy that table into the PR description under `## Bench`. `python3 Scripts/bench_compare.py --self-test` locks the comparison, the markdown fixture shapes, and that the bench drives keys. `Scripts/check_boundaries.py` fails if `ci.yml` drops `Scripts/bench.sh`. |
| Quill is fast, simple, and keyboard driven | The perf gate is the speed check. `Scripts/bench.sh` and `Scripts/bench_compare.py` stay bash plus the Python stdlib, which `--self-test` enforces. The suite types vim keys (`KeyEvent`, `<leader>sf`, `<leader>sg`) instead of driving the pointer. |
| Quill's only job is a great markdown editing experience | Benchmarks are long-form markdown: prose, headings, lists, tables, links, and code blocks, including 1k, 50k, and 500k-line notes. `--self-test` fails if the fixture generator drops those shapes or those sizes. |

When a rule is already in this table and nothing fails if an agent skips it, fix the enforcer in the same change. Branch protection is not set from this repo's automation token. A repo admin has to mark the `macos` check required.
