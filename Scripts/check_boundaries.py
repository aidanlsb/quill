#!/usr/bin/env python3
"""Fail when a concurrency escape has no justification, or bare NSApp returns.

A line of Swift that contains nonisolated(unsafe) or @unchecked Sendable must
have a nearby `// quill-concurrency:` comment whose reason is at least 20
characters. The historical miss was `nonisolated(unsafe) let buffer = buffer`
with no required marker, which is what agents copy.

Bare `NSApp` traps when the singleton is nil during SwiftUI init. The
historical line was `NSApp.effectiveAppearance` in QuillTheme.current. Use
`NSApp?` while the application object may be nil, or `NSApplication.shared`
after launch.

macOS /bin/bash is 3.2. `"${array[@]}"` with `set -u` is an unbound variable
when the array is empty. The historical lines were `open ${wait_flag[@]}` and
`open_app "${urls[@]}"` in Scripts/quill. Write `${name[@]+"${name[@]}"}`.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

MARKER = "quill-concurrency:"
MIN_REASON = 20
ROOT = Path(__file__).resolve().parents[1]

HISTORICAL = {
    "VimTextView.swift": "        nonisolated(unsafe) let buffer = buffer\n",
    "TextKit2Layout.swift": "final class TextKit2Layout: TextLayout, @unchecked Sendable {\n",
}
HISTORICAL_NSAPP = "        let appearance = NSApp.effectiveAppearance\n"
BARE_NSAPP = re.compile(r"(?<![A-Za-z0-9_])NSApp(?![A-Za-z0-9_?])")
SAFE_ARRAY = re.compile(
    r"\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\+\"\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}\"\}"
)
ANY_ARRAY = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}")
HISTORICAL_BASH = """
open ${wait_flag[@]} -a Quill "$@"
open_app "${urls[@]}"
"""


def code_only(line: str) -> str:
    out: list[str] = []
    i = 0
    quote = ""
    while i < len(line):
        ch = line[i]
        if quote:
            out.append(ch)
            if ch == "\\" and i + 1 < len(line):
                out.append(line[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = ""
            i += 1
            continue
        if ch in "\"'":
            quote = ch
            out.append(ch)
            i += 1
            continue
        if line[i : i + 2] == "//":
            break
        out.append(ch)
        i += 1
    return "".join(out)


def has_reason(lines: list[str], index: int) -> bool:
    start = max(0, index - 8)
    for line in lines[start : index + 1]:
        if MARKER not in line:
            continue
        reason = line.split(MARKER, 1)[1].strip()
        if len(reason) >= MIN_REASON:
            return True
    return False


def scan_swift(text: str, path: str) -> list[str]:
    errors: list[str] = []
    lines = text.splitlines()
    for index, line in enumerate(lines):
        code = code_only(line)
        if "nonisolated(unsafe)" not in code and "@unchecked Sendable" not in code:
            continue
        if has_reason(lines, index):
            continue
        errors.append(
            f"{path}:{index + 1}: add `// {MARKER} <why this escape is safe>` "
            f"within the previous 8 lines ({MIN_REASON} characters minimum). "
            f"Offending line: {line.strip()}"
        )
    return errors


def scan_nsapp(text: str, path: str) -> list[str]:
    errors: list[str] = []
    for index, line in enumerate(text.splitlines()):
        code = code_only(line)
        if not BARE_NSAPP.search(code):
            continue
        errors.append(
            f"{path}:{index + 1}: bare NSApp traps when the application object is nil "
            f"during SwiftUI init. Use NSApp? or NSApplication.shared. "
            f"Offending line: {line.strip()}"
        )
    return errors


def scan_bash(text: str, path: str) -> list[str]:
    errors: list[str] = []
    for index, line in enumerate(text.splitlines()):
        code = line.split("#", 1)[0]
        if ANY_ARRAY.search(SAFE_ARRAY.sub("", code)):
            errors.append(
                f"{path}:{index + 1}: unguarded array expansion breaks bash 3.2 under set -u "
                f"when the array is empty. Write ${{name[@]+\"${{name[@]}}\"}}. "
                f"Offending line: {line.strip()}"
            )
    return errors


def shell_files() -> list[Path]:
    found: list[Path] = []
    scripts = ROOT / "Scripts"
    for path in sorted(scripts.iterdir()):
        if not path.is_file():
            continue
        if path.suffix == ".sh" or path.name in {"quill", "verify-quill"}:
            found.append(path)
    return found


def scan_shell_tree() -> list[str]:
    errors: list[str] = []
    for path in shell_files():
        errors.extend(scan_bash(path.read_text(), str(path.relative_to(ROOT))))
    return errors


WIRING_FILE = "Sources/Quill/VimTextView.swift"
MAKE_CALL = re.compile(r"VimTextView\.make\(")
COMMON_INIT_CALL = re.compile(r"\.commonInit\(\)")


def scan_wiring(text: str, path: str) -> list[str]:
    if path == WIRING_FILE:
        return []
    errors: list[str] = []
    for index, line in enumerate(text.splitlines()):
        code = code_only(line)
        if not MAKE_CALL.search(code) and not COMMON_INIT_CALL.search(code):
            continue
        errors.append(
            f"{path}:{index + 1}: wire editor views only through "
            f"VimTextView.host(engine:frame:). "
            f"VimTextView.make( and .commonInit() belong in {WIRING_FILE}. "
            f"Offending line: {line.strip()}"
        )
    return errors


def scan_tree() -> list[str]:
    errors: list[str] = []
    for folder in ("Sources", "Tests"):
        for path in sorted((ROOT / folder).rglob("*.swift")):
            text = path.read_text()
            relative = str(path.relative_to(ROOT))
            errors.extend(scan_swift(text, relative))
            errors.extend(scan_nsapp(text, relative))
            errors.extend(scan_wiring(text, relative))
    return errors


def workflow_passes_complete_checking() -> list[str]:
    text = (ROOT / ".github/workflows/ci.yml").read_text()
    needed = (
        "swift test -Xswiftc -strict-concurrency=complete",
        "swift build -c release --product Quill -Xswiftc -strict-concurrency=complete",
        "shellcheck -s bash",
    )
    return [f"ci.yml is missing `{item}`" for item in needed if item not in text]


def workflow_has_perf_gate() -> list[str]:
    text = (ROOT / ".github/workflows/ci.yml").read_text()
    needed = (
        "Scripts/bench.sh",
        "python3 Scripts/bench_compare.py --self-test",
    )
    return [f"ci.yml is missing `{item}`" for item in needed if item not in text]


def agents_mentions_principles() -> list[str]:
    path = ROOT / "AGENTS.md"
    if not path.is_file():
        return ["AGENTS.md is missing"]
    text = path.read_text()
    needed = (
        "perf gate",
        "fast, simple, and keyboard driven",
        "great markdown editing experience",
    )
    return [f"AGENTS.md is missing `{item}`" for item in needed if item not in text]


def self_test() -> int:
    failed = False
    for name, text in HISTORICAL.items():
        found = scan_swift(text, name)
        if not found:
            print(f"self-test: historical {name} was accepted", file=sys.stderr)
            failed = True
        else:
            print(f"self-test: rejected historical {name}")
    justified = (
        "// quill-concurrency: TextBuffer is not Sendable; the call is synchronous on the main thread.\n"
        "nonisolated(unsafe) let buffer = buffer\n"
    )
    if scan_swift(justified, "good.swift"):
        print("self-test: a justified escape was rejected", file=sys.stderr)
        failed = True
    short = "// quill-concurrency: unsafe\nnonisolated(unsafe) let buffer = buffer\n"
    if not scan_swift(short, "short.swift"):
        print("self-test: a too-short reason was accepted", file=sys.stderr)
        failed = True
    if not scan_nsapp(HISTORICAL_NSAPP, "Theme.swift"):
        print("self-test: historical NSApp.effectiveAppearance was accepted", file=sys.stderr)
        failed = True
    else:
        print("self-test: rejected historical Theme.swift NSApp.effectiveAppearance")
    safe_nsapp = "let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()\n"
    if scan_nsapp(safe_nsapp, "safe.swift") or scan_nsapp("NSApplication.shared.keyWindow?.close()\n", "shared.swift"):
        print("self-test: NSApp? or NSApplication.shared was rejected", file=sys.stderr)
        failed = True
    if scan_nsapp("/// `NSApp` is not required; the URL is queued.\n", "comment.swift"):
        print("self-test: a comment mentioning NSApp was rejected", file=sys.stderr)
        failed = True
    historical_bash = scan_bash(HISTORICAL_BASH, "Scripts/quill")
    if len(historical_bash) < 2:
        print("self-test: historical bash 3.2 array expansions were accepted", file=sys.stderr)
        failed = True
    else:
        print("self-test: rejected historical Scripts/quill array expansions")
    safe_bash = 'open ${wait_flag[@]+"${wait_flag[@]}"} -a Quill "$@"\n'
    if scan_bash(safe_bash, "Scripts/quill"):
        print("self-test: the guarded array expansion was rejected", file=sys.stderr)
        failed = True
    bypass = "let tv = VimTextView.make()\ntv.commonInit()\n"
    if len(scan_wiring(bypass, "Sources/Quill/AppSmoke.swift")) < 2:
        print("self-test: VimTextView.make() from AppSmoke.swift was accepted", file=sys.stderr)
        failed = True
    else:
        print("self-test: rejected VimTextView.make() outside VimTextView.swift")
    factory = "let hosted = VimTextView.host(engine: engine)\n"
    if scan_wiring(factory, "Sources/Quill/AppSmoke.swift") or scan_wiring(
        "let tv = VimTextView.make(frame: frame)\n", WIRING_FILE
    ):
        print("self-test: VimTextView.host(engine:) or make inside VimTextView.swift was rejected", file=sys.stderr)
        failed = True
    repo = scan_tree() + scan_shell_tree()
    workflow = workflow_passes_complete_checking() + workflow_has_perf_gate() + agents_mentions_principles()
    if repo or workflow:
        print("self-test: repository failed the boundary check", file=sys.stderr)
        for error in repo + workflow:
            print(error, file=sys.stderr)
        failed = True
    if failed:
        return 1
    print(
        "check_boundaries: concurrency escapes are justified, bare NSApp is rejected, "
        "bash 3.2 array expansions are guarded, and CI runs shellcheck plus -strict-concurrency=complete"
    )
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    errors = (
        scan_tree()
        + scan_shell_tree()
        + workflow_passes_complete_checking()
        + workflow_has_perf_gate()
        + agents_mentions_principles()
    )
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    print("check_boundaries: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
