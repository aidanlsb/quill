#!/usr/bin/env python3
"""Median cold-start and `quill <file>` measurements.

Cold launch execs the release binary. `file-open` is `open -a` (the previous
`quill file.md` path). `file` is the direct-spawn CLI. The app writes one
JSON report per run.
A fifo wakes the timer so the wait is not a poll.

    python3 Scripts/startup-bench.py --self-test
    python3 Scripts/startup-bench.py --bin PATH --app dist/Quill.app --runs 7 --warmup 1
"""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from urllib.parse import quote

REQUEST = "/tmp/quill-startup-request"
PREFIX = "Quill startup sample"


def median(values: list[float]) -> float:
    if not values:
        raise ValueError("empty")
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2


def sample_note() -> str:
    lines = [
        PREFIX,
        "",
        "# Heading",
        "",
        "A paragraph with **bold** and `code`.",
        "",
    ]
    for index in range(80):
        lines.append(
            f"Line {index} continues the note with a [link](https://example.com) and `code`."
        )
    return "\n".join(lines) + "\n"


class Clock:
    def __init__(self) -> None:
        self._libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        self._libc.mach_absolute_time.restype = ctypes.c_uint64

        class Timebase(ctypes.Structure):
            _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

        info = Timebase()
        self._libc.mach_timebase_info(ctypes.byref(info))
        self._numer = int(info.numer)
        self._denom = int(info.denom) or 1

    def nanos(self) -> int:
        return int(self._libc.mach_absolute_time()) * self._numer // self._denom


def write_request(fifo: str, out: str, expect: str | None) -> None:
    lines = [
        "quill-startup=1",
        f"deadline={time.time() + 60:.0f}",
        f"fifo={fifo}",
        f"out={out}",
    ]
    if expect is not None:
        lines.append(f"expect={expect}")
        lines.append(f"prefix={PREFIX}")
    tmp = REQUEST + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, REQUEST)


def quiet_kill() -> None:
    subprocess.run(["pkill", "-x", "Quill"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 5
    while time.time() < deadline:
        probe = subprocess.run(["pgrep", "-x", "Quill"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if probe.returncode != 0:
            return
        time.sleep(0.05)


def listen(fifo: str, ready: str, box: dict[str, int], clock: Clock) -> None:
    fd = os.open(fifo, os.O_RDWR)
    with open(ready, "w", encoding="utf-8") as handle:
        handle.write("ok")
    os.read(fd, 1)
    box["ns"] = clock.nanos()
    os.close(fd)


def wait_for(path: str, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            return True
        time.sleep(0.01)
    return False


def run_once(
    clock: Clock,
    kind: str,
    binary: str,
    app: str,
    note: str,
    dest: Path,
    root: Path,
) -> dict[str, object]:
    quiet_kill()
    try:
        os.remove(REQUEST)
    except FileNotFoundError:
        pass
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        dest.unlink()
    fifo = f"/tmp/quill-startup-fifo-{os.getpid()}-{kind}-{dest.stem}"
    ready = fifo + ".ready"
    for path in (fifo, ready):
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
    os.mkfifo(fifo)
    box: dict[str, int] = {}
    thread = threading.Thread(target=listen, args=(fifo, ready, box, clock), daemon=True)
    thread.start()
    if not wait_for(ready, 5):
        raise RuntimeError("startup fifo listener did not arm")
    expect = note if kind != "cold" else None
    write_request(fifo, str(dest.resolve()), expect)
    log_path = dest.with_suffix(".log")
    start = clock.nanos()
    proc: subprocess.Popen[bytes] | None = None
    try:
        env = os.environ.copy()
        env["QUILL_APP"] = app
        if kind == "cold":
            log = open(log_path, "w", encoding="utf-8")
            proc = subprocess.Popen([binary], stdout=log, stderr=subprocess.STDOUT)
        elif kind == "file-open":
            url = "quill://open?path=" + quote(note, safe="/-._~")
            with open(log_path, "w", encoding="utf-8") as log:
                subprocess.run(
                    ["/usr/bin/open", "-a", app, url],
                    cwd=root,
                    env=env,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    check=False,
                )
        else:
            cli = str(Path(app) / "Contents" / "MacOS" / "QuillCLI")
            if not os.access(cli, os.X_OK):
                raise RuntimeError(f"QuillCLI is missing: {cli}")
            env["QUILL_LAUNCH_MARK"] = "1"
            # Unbuffered. A text-mode file object can drop what the child wrote to the fd.
            with open(log_path, "wb", buffering=0) as log:
                subprocess.run(
                    [cli, note],
                    cwd=root,
                    env=env,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    check=False,
                )
        source = "timeout"
        deadline = time.time() + 20
        while time.time() < deadline:
            if "ns" in box:
                source = "fifo"
                break
            if dest.is_file() and dest.stat().st_size > 0:
                time.sleep(0.05)
                source = "fifo" if "ns" in box else "file"
                if source == "file":
                    box["ns"] = clock.nanos()
                break
            time.sleep(0.002)
        if proc is not None:
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        wall = (box["ns"] - start) / 1_000_000 if "ns" in box else None
        report: dict[str, object] = {}
        if dest.is_file():
            report = json.loads(dest.read_text(encoding="utf-8"))
        report["wallMs"] = wall
        report["wallSource"] = source
        report["log"] = str(log_path)
        if wall is not None and isinstance(report.get("launchToEditableMs"), (int, float)):
            report["beforeDelegateMs"] = float(wall) - float(report["launchToEditableMs"])
        if kind == "file":
            text = log_path.read_text(encoding="utf-8", errors="replace") if log_path.is_file() else ""
            if "quill launch direct" not in text:
                report["ok"] = False
                snippet = " ".join(text.split())
                report["reason"] = "launcher did not spawn directly: " + snippet[:240]
        dest.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        editable = report.get("launchToEditableMs")
        print(
            f"  ok={report.get('ok')} editable={editable} wall={wall} "
            f"key={report.get('launchToKeyMs')} focused={report.get('focused')} "
            f"active={report.get('active')} waiting={report.get('waiting')} source={source}",
            flush=True,
        )
        printed = timeline(report)
        if printed:
            print(printed, flush=True)
        elif log_path.is_file():
            text = log_path.read_text(encoding="utf-8", errors="replace")
            print(text[-2000:], flush=True)
        return report
    finally:
        try:
            os.remove(REQUEST)
        except FileNotFoundError:
            pass
        for path in (fifo, ready):
            try:
                os.remove(path)
            except FileNotFoundError:
                pass


def timeline(report: dict[str, object]) -> str:
    marks = report.get("marks")
    lines = []
    if isinstance(marks, list) and marks:
        previous = 0.0
        for item in marks:
            if not isinstance(item, dict):
                continue
            ms = float(item.get("ms", 0))
            lines.append(f"    {ms:8.2f}  +{ms - previous:7.2f}  {item.get('name')}")
            previous = ms
    spans = report.get("spans")
    if isinstance(spans, list) and spans:
        lines.append("    spans:")
        for item in spans:
            if not isinstance(item, dict):
                continue
            lines.append(
                f"    {float(item.get('startMs', 0)):8.2f}  {float(item.get('ms', 0)):7.2f}  {item.get('name')}"
            )
    return "\n".join(lines)


def summarize(kind: str, runs: list[dict[str, object]]) -> str:
    def numbers(key: str) -> list[float]:
        found = []
        for run in runs:
            value = run.get(key)
            if isinstance(value, (int, float)) and value >= 0:
                found.append(float(value))
        return found

    editable = numbers("launchToEditableMs")
    wall = numbers("wallMs")
    key = numbers("launchToKeyMs")
    lines = [
        f"quill startup-bench {kind} n={len(runs)} ok={sum(1 for run in runs if run.get('ok') is True)}",
        f"  launchToEditableMs median={median(editable):.2f}  min={min(editable):.2f}  max={max(editable):.2f}"
        if editable
        else "  launchToEditableMs median=missing",
        f"  wallMs median={median(wall):.2f}  min={min(wall):.2f}  max={max(wall):.2f}" if wall else "  wallMs median=missing",
        f"  launchToKeyMs median={median(key):.2f}" if key else "  launchToKeyMs median=missing",
        f"  focused={sum(1 for run in runs if run.get('focused') is True)}/{len(runs)}"
        f" active={sum(1 for run in runs if run.get('active') is True)}/{len(runs)}",
    ]
    before = numbers("beforeDelegateMs")
    if before:
        lines.append(f"  beforeDelegateMs median={median(before):.2f}")
    with_marks = [run for run in runs if isinstance(run.get("marks"), list) and run.get("marks")]
    if with_marks:
        if editable:
            target = median(editable)
            closest = min(
                with_marks,
                key=lambda run: abs(float(run["launchToEditableMs"]) - target)
                if isinstance(run.get("launchToEditableMs"), (int, float))
                else 1e9,
            )
            lines.append("  timeline of the run closest to the median:")
        else:
            closest = with_marks[0]
            lines.append("  timeline of the first run:")
        lines.append(timeline(closest))
    failed = [run for run in runs if run.get("ok") is not True]
    for run in failed:
        lines.append(
            f"  FAIL reason={run.get('reason') or run.get('waiting') or 'missing report'} "
            f"waiting={run.get('waiting')} log={run.get('log')}"
        )
    return "\n".join(lines)


def comparison_table(before: list[dict[str, object]], after: list[dict[str, object]]) -> str:
    def med(runs: list[dict[str, object]], key: str) -> float | None:
        values = [
            float(run[key])
            for run in runs
            if isinstance(run.get(key), (int, float)) and float(run[key]) >= 0
        ]
        return median(values) if values else None

    lines = [
        "| case | metric | open -a median | direct median | factor |",
        "|---|---|---:|---:|---:|",
    ]
    for key in ("wallMs", "launchToEditableMs", "launchToKeyMs", "beforeDelegateMs"):
        left = med(before, key)
        right = med(after, key)
        left_text = "missing" if left is None else f"{left:.2f}"
        right_text = "missing" if right is None else f"{right:.2f}"
        if left is None or right is None or right == 0:
            factor = "n/a"
        else:
            factor = f"{left / right:.2f}x"
        lines.append(f"| quill file.md | {key} | {left_text} | {right_text} | {factor} |")

    def ready(runs: list[dict[str, object]]) -> str:
        count = sum(1 for run in runs if run.get("focused") is True and run.get("active") is True)
        return f"{count}/{len(runs)}"

    lines.append(f"| quill file.md | focused+active | {ready(before)} | {ready(after)} | |")
    return "\n".join(lines)


def measure(args: argparse.Namespace) -> int:
    if platform.system() != "Darwin":
        print("startup-bench: Quill is an AppKit app. This host cannot launch it.", file=sys.stderr)
        return 1
    binary = str(Path(args.bin).resolve())
    app = str(Path(args.app).resolve())
    if not os.access(binary, os.X_OK):
        print(f"startup-bench: binary is not executable: {binary}", file=sys.stderr)
        return 1
    if not os.path.isdir(app):
        print(f"startup-bench: app bundle is missing: {app}", file=sys.stderr)
        return 1
    root = Path(__file__).resolve().parents[1]
    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    note_dir = Path(tempfile.mkdtemp(prefix="quill-startup-note-"))
    note = note_dir / "sample.md"
    note.write_text(sample_note(), encoding="utf-8")
    clock = Clock()
    summaries = []
    failed = False
    kept_by_kind: dict[str, list[dict[str, object]]] = {}
    try:
        for kind in ("cold", "file-open", "file"):
            kept: list[dict[str, object]] = []
            total = args.warmup + args.runs
            for index in range(total):
                label = "warmup" if index < args.warmup else str(index - args.warmup + 1)
                dest = out / f"{kind}-{label}.json"
                print(f"startup-bench: {kind} {label}", flush=True)
                report = run_once(clock, kind, binary, app, str(note), dest, root)
                if index >= args.warmup:
                    kept.append(report)
            kept_by_kind[kind] = kept
            text = summarize(kind, kept)
            print(text, flush=True)
            summaries.append(text)
            if any(run.get("ok") is not True for run in kept):
                failed = True
            if not any(isinstance(run.get("launchToEditableMs"), (int, float)) for run in kept):
                failed = True
        table = comparison_table(kept_by_kind.get("file-open", []), kept_by_kind.get("file", []))
        print(table, flush=True)
        summaries.append(table)
    finally:
        quiet_kill()
        shutil.rmtree(note_dir, ignore_errors=True)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write("## Startup\n\n```\n")
            handle.write("\n\n".join(summaries))
            handle.write("\n```\n")
    (out / "summary.txt").write_text("\n\n".join(summaries) + "\n", encoding="utf-8")
    return 1 if failed else 0


def self_test() -> int:
    if median([10, 30, 20]) != 20:
        print("self-test: odd median", file=sys.stderr)
        return 1
    if median([1, 2, 3, 4]) != 2.5:
        print("self-test: even median", file=sys.stderr)
        return 1
    try:
        median([])
    except ValueError:
        pass
    else:
        print("self-test: empty median was accepted", file=sys.stderr)
        return 1
    note = sample_note()
    if not note.startswith(PREFIX) or "\n# Heading\n" not in note:
        print("self-test: sample note lost its heading", file=sys.stderr)
        return 1
    text = summarize(
        "cold",
        [
            {"ok": True, "launchToEditableMs": 10, "wallMs": 30, "launchToKeyMs": 8, "marks": [{"name": "delegateInit", "ms": 0.1}, {"name": "editable", "ms": 10}]},
            {"ok": True, "launchToEditableMs": 30, "wallMs": 50, "launchToKeyMs": 20, "marks": []},
            {"ok": False, "waiting": "key", "reason": "timeout"},
        ],
    )
    if "launchToEditableMs median=20.00" not in text or "FAIL" not in text:
        print(text, file=sys.stderr)
        print("self-test: summary", file=sys.stderr)
        return 1
    table = comparison_table(
        [{"ok": True, "wallMs": 400, "launchToEditableMs": 300, "launchToKeyMs": 280, "beforeDelegateMs": 100, "focused": True, "active": True}],
        [{"ok": True, "wallMs": 200, "launchToEditableMs": 180, "launchToKeyMs": 170, "beforeDelegateMs": 20, "focused": True, "active": True}],
    )
    if "| quill file.md | wallMs | 400.00 | 200.00 | 2.00x |" not in table:
        print(table, file=sys.stderr)
        print("self-test: comparison table", file=sys.stderr)
        return 1
    if "focused+active | 1/1 | 1/1 |" not in table:
        print(table, file=sys.stderr)
        print("self-test: focus row", file=sys.stderr)
        return 1
    print("startup-bench: self-test passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Measure Quill startup medians")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--bin")
    parser.add_argument("--app")
    parser.add_argument("--runs", type=int, default=7)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--out", default="artifacts/startup")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.bin or not args.app:
        parser.error("--bin and --app are required")
    if args.runs < 1 or args.warmup < 0:
        parser.error("--runs must be >= 1 and --warmup >= 0")
    return measure(args)


if __name__ == "__main__":
    sys.exit(main())
