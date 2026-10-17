#!/usr/bin/env python3
"""Fail when a concurrency escape has no justification.

A line of Swift that contains nonisolated(unsafe) or @unchecked Sendable must
have a nearby `// quill-concurrency:` comment whose reason is at least 20
characters. The historical miss was `nonisolated(unsafe) let buffer = buffer`
with no required marker, which is what agents copy.
"""

from __future__ import annotations

import sys
from pathlib import Path

MARKER = "quill-concurrency:"
MIN_REASON = 20
ROOT = Path(__file__).resolve().parents[1]

HISTORICAL = {
    "VimTextView.swift": "        nonisolated(unsafe) let buffer = buffer\n",
    "TextKit2Layout.swift": "final class TextKit2Layout: TextLayout, @unchecked Sendable {\n",
}


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


def scan_tree() -> list[str]:
    errors: list[str] = []
    for folder in ("Sources", "Tests"):
        for path in sorted((ROOT / folder).rglob("*.swift")):
            errors.extend(scan_swift(path.read_text(), str(path.relative_to(ROOT))))
    return errors


def workflow_passes_complete_checking() -> list[str]:
    text = (ROOT / ".github/workflows/ci.yml").read_text()
    needed = (
        "swift test -Xswiftc -strict-concurrency=complete",
        "swift build -c release --product Quill -Xswiftc -strict-concurrency=complete",
    )
    return [f"ci.yml is missing `{item}`" for item in needed if item not in text]


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
    repo = scan_tree()
    workflow = workflow_passes_complete_checking()
    if repo or workflow:
        print("self-test: repository failed the boundary check", file=sys.stderr)
        for error in repo + workflow:
            print(error, file=sys.stderr)
        failed = True
    if failed:
        return 1
    print("check_boundaries: concurrency escapes are justified and CI passes -strict-concurrency=complete")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    errors = scan_tree() + workflow_passes_complete_checking()
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    print("check_boundaries: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
