#!/usr/bin/env python3
"""Compare Quill benchmark JSON and build the markdown fixtures.

The PR gate fails when a metric is slower than the base commit by more than
the ratio and the absolute delta is above that metric's floor. Both builds
run on the same machine, so the floor only has to clear run-to-run noise.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RATIO = 0.15
P99_RATIO = 0.25
# Absolute floors in the metric's unit (milliseconds, or MB for rss*).
# A slowdown must clear BOTH the ratio and the floor. p95 is judged when a
# run has at least 5 samples; p99 when it has at least 15. Cold one-shot
# samples are gated on the median across process runs.
#
# Each triple is (median, p95, p99). A floor is about three times the
# run-to-run spread of medians on macos-26, run 39198744980 (three suite
# processes, five cold launches), and never below the previous floor.
# Spread is max(run median) - min(run median). The same-runner gate still
# requires a 15% slowdown, so a floor this high only lets through a move
# larger than the noise that job actually saw.
FLOORS = {
    "launchToKeyMs": (210.0, 210.0, 210.0),
    "open1kMs": (4.0, 8.0, 12.0),
    "open50kMs": (140.0, 140.0, 140.0),
    "open500kMs": (610.0, 610.0, 610.0),
    "open500kColdMs": (770.0, 770.0, 770.0),
    "openHeavyMs": (24.0, 24.0, 24.0),
    "keyInsertTopMs": (1.8, 1.8, 1.8),
    "keyInsertMidMs": (3.5, 3.5, 3.5),
    "keyInsertEndMs": (2.6, 2.6, 2.6),
    "keyNormalTopMs": (3.5, 3.5, 3.5),
    "keyNormalMidMs": (3.0, 3.0, 3.0),
    "keyNormalEndMs": (2.3, 2.3, 2.3),
    # j/w medians stay under a millisecond. Their p95 is a hitch: most
    # samples are cheap and one layout sample is ~150ms, so the percentile
    # moves by 60–90ms between identical runs (pull_request run 39200933604).
    "motionJMs": (0.40, 190.0, 430.0),
    "motionKMs": (1.5, 270.0, 360.0),
    "motionWMs": (0.40, 200.0, 200.0),
    "motionGMs": (2.3, 3.0, 6.0),
    "motionGFirstMs": (20.0, 50.0, 80.0),
    "motionGgMs": (3.4, 3.4, 4.0),
    "motionSearchMs": (14.0, 14.0, 14.0),
    "motionDdMs": (4.5, 4.5, 4.5),
    "motionUndoMs": (12.0, 12.0, 12.0),
    "motionRedoMs": (12.0, 12.0, 12.0),
    "restyleProseMs": (0.30, 1.0, 2.0),
    "restyleTableMs": (0.40, 1.20, 2.50),
    "resizeMs": (4.0, 6.0, 10.0),
    "scrollMs": (0.25, 0.50, 1.0),
    "pickerSfMs": (80.0, 80.0, 80.0),
    "pickerSfColdMs": (160.0, 160.0, 160.0),
    "pickerSfKeyMs": (1.6, 1.6, 2.0),
    "pickerSgMs": (140.0, 140.0, 140.0),
    "pickerSgColdMs": (2000.0, 2000.0, 2000.0),
    "directoryMs": (9.0, 12.0, 20.0),
    "directoryColdMs": (8.0, 20.0, 40.0),
    "rssSteadyMb": (25.0, 40.0, 60.0),
    "rssPeakMb": (40.0, 80.0, 120.0),
}

PROSE_LINES = {
    "prose-1k.md": 1000,
    "prose-50k.md": 50_000,
    "prose-500k.md": 500_000,
}
HEAVY_LINES = 4000
NOTE_COUNT = 2000
WIDE_COUNT = 400
VENDOR_COUNT = 200
STAMP_FULL = "v1 full"
STAMP_QUICK = "v1 quick"

ADD_CALL = re.compile(r'add\("([A-Za-z0-9]+)"')
IMPORT_LINE = re.compile(r"^\s*(?:import|from)\s+([A-Za-z0-9_]+)", re.MULTILINE)
ALLOWED_IMPORTS = {"__future__", "argparse", "json", "pathlib", "re", "shutil", "sys", "tempfile"}


def markdown_cycle() -> list[str]:
    """One repeating section of the notes the editor is for."""
    return [
        "# Heading {n}",
        "",
        "The paragraph stays on the measure. It mentions [a note](notes/{n}.md) and a [[topic-{n}]].",
        "",
        "- first point of section {n}",
        "- second point with `inline code`",
        "- [ ] open task {n}",
        "",
        "| word | note | mark |",
        "| --- | --- | --- |",
        "| alpha | {n} | link |",
        "| beta | row | cell |",
        "",
        "```swift",
        "func block{n}() -> Int { {n} }",
        "```",
        "",
    ]


def write_markdown(path: Path, count: int) -> None:
    cycle = markdown_cycle()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        if count <= 0:
            return
        written = 0
        section = 0
        while written < count - 1:
            for line in cycle:
                if written >= count - 1:
                    break
                handle.write(line.replace("{n}", str(section)))
                handle.write("\n")
                written += 1
            section += 1
        handle.write("<!-- quill-bench-end -->\n")


def write_repo(root: Path, notes: int, wide: int, vendor: int) -> None:
    repo = root / "repo"
    notes_dir = repo / "notes"
    wide_dir = repo / "wide"
    wide_b = repo / "wide-b"
    vendor_dir = repo / "vendor"
    for folder in (notes_dir, wide_dir, wide_b, vendor_dir):
        folder.mkdir(parents=True, exist_ok=True)
    (repo / ".gitignore").write_text("vendor/\n", encoding="utf-8")
    (repo / "readme.md").write_text(
        "# Fixture repo\n\nPicker and grep root.\n",
        encoding="utf-8",
    )
    total = max(notes, 1)
    for index in range(notes):
        needle = "\n\nquillbench-needle appears here.\n" if index % 80 == 0 else "\n"
        name = f"n{index:04d}.md"
        link = f"n{(index + 1) % total:04d}.md"
        (notes_dir / name).write_text(
            f"# Note {index}\n\nA short note with [link]({link}) and [[{name}]].{needle}",
            encoding="utf-8",
        )
    for folder in (wide_dir, wide_b):
        for index in range(wide):
            (folder / f"w{index:04d}.md").write_text(
                f"# Wide {index}\n\n- item {index}\n",
                encoding="utf-8",
            )
    for index in range(vendor):
        (vendor_dir / f"v{index:04d}.md").write_text("skip\n", encoding="utf-8")


def write_fixtures(dest: Path, quick: bool) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    stamp = dest / "STAMP"
    token = STAMP_QUICK if quick else STAMP_FULL
    if stamp.is_file() and stamp.read_text(encoding="utf-8") == token:
        print(f"bench fixtures: reuse {dest}")
        return
    for child in dest.iterdir():
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()
    if quick:
        write_markdown(dest / "prose-1k.md", 200)
        write_markdown(dest / "heavy.md", 80)
        write_repo(dest, notes=30, wide=12, vendor=4)
    else:
        for name, count in PROSE_LINES.items():
            print(f"bench fixtures: {name} ({count} lines)")
            write_markdown(dest / name, count)
        print(f"bench fixtures: heavy.md ({HEAVY_LINES} lines)")
        write_markdown(dest / "heavy.md", HEAVY_LINES)
        print(f"bench fixtures: repo ({NOTE_COUNT} notes)")
        write_repo(dest, notes=NOTE_COUNT, wide=WIDE_COUNT, vendor=VENDOR_COUNT)
    stamp.write_text(token, encoding="utf-8")
    print(f"bench fixtures: {dest}")


def percentile(values: list[float], p: float) -> float:
    if not values:
        raise ValueError("empty sample")
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = p * (len(ordered) - 1)
    lo = int(rank)
    hi = min(lo + 1, len(ordered) - 1)
    fraction = rank - lo
    return ordered[lo] * (1 - fraction) + ordered[hi] * fraction


def aggregate_dir(directory: Path) -> dict:
    paths = sorted(directory.glob("*.json"))
    if not paths:
        raise SystemExit(f"aggregate: no json in {directory}")
    grouped: dict[str, list[dict]] = {}
    host = None
    sha = ""
    for path in paths:
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("host"):
            host = data["host"]
        if data.get("sha"):
            sha = data["sha"]
        for name, metric in data.get("metrics", {}).items():
            grouped.setdefault(name, []).append(metric)
    metrics = {}
    runs = {}
    noise = {}
    for name in sorted(grouped):
        items = grouped[name]
        ns = [int(item["n"]) for item in items]
        medians = [float(item["median"]) for item in items]
        p95s = [float(item["p95"]) for item in items]
        p99s = [float(item["p99"]) for item in items]
        if ns and all(n == 1 for n in ns):
            summary = {
                "median": percentile(medians, 0.50),
                "p95": percentile(medians, 0.95),
                "p99": percentile(medians, 0.99),
                "n": len(medians),
            }
        else:
            summary = {
                "median": percentile(medians, 0.50),
                "p95": percentile(p95s, 0.50),
                "p99": percentile(p99s, 0.50),
                "n": min(ns) if ns else 0,
            }
        metrics[name] = summary
        runs[name] = {"median": medians, "p95": p95s, "p99": p99s}
        mid = summary["median"]
        spread = max(medians) - min(medians)
        noise[name] = {
            "spread": spread,
            "spreadRatio": 0.0 if mid == 0 else spread / mid,
            "min": min(medians),
            "max": max(medians),
        }
    return {
        "version": 1,
        "lowerIsBetter": True,
        "sha": sha,
        "host": host,
        "metrics": metrics,
        "runs": runs,
        "noise": noise,
    }


def write_json(path: Path, doc: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")


def unit_of(name: str) -> str:
    if name.startswith("rss"):
        return "MB"
    return "ms"


def fmt_num(value: float, unit: str) -> str:
    if unit == "MB":
        return f"{value:.1f}"
    if abs(value) >= 100:
        return f"{value:.1f}"
    if abs(value) >= 10:
        return f"{value:.2f}"
    return f"{value:.3f}"


def gated_stats(n: int) -> list[str]:
    stats = ["median"]
    if n >= 5:
        stats.append("p95")
    if n >= 15:
        stats.append("p99")
    return stats


def floor_for(name: str, stat: str) -> float:
    triple = FLOORS[name]
    if stat == "median":
        return triple[0]
    if stat == "p95":
        return triple[1]
    return triple[2]


def ratio_for(stat: str) -> float:
    if stat == "p99":
        return P99_RATIO
    return RATIO


def worse(base: float, cand: float, ratio: float, floor: float) -> bool:
    delta = cand - base
    if delta <= 0:
        return False
    if base <= 0:
        return delta > floor
    return delta > floor and (delta / base) > ratio


def delta_text(base: float, cand: float, unit: str) -> str:
    delta = cand - base
    absolute = fmt_num(delta, unit)
    sign = "+" if delta > 0 else ""
    if base == 0:
        return f"{sign}{absolute}{unit}"
    pct = delta / base * 100
    return f"{sign}{pct:.1f}% ({sign}{absolute}{unit})"


def compare_docs(
    candidate: dict,
    baseline: dict,
    candidate_label: str,
    baseline_label: str,
) -> tuple[str, int]:
    left = baseline.get("metrics") or {}
    right = candidate.get("metrics") or {}
    names = sorted(set(left) | set(right))
    failures: list[str] = []
    rows: list[str] = []
    p99_notes: list[str] = []
    if not names:
        text = (
            "<!-- quill-bench -->\n\n"
            "## Bench\n\n"
            "No measurements to compare.\n"
        )
        return text, 1
    for name in names:
        if name not in FLOORS:
            failures.append(f"{name}: no floor configured in Scripts/bench_compare.py")
            continue
        if name not in left or name not in right:
            failures.append(f"{name}: missing from {baseline_label if name not in left else candidate_label}")
            continue
        base = left[name]
        cand = right[name]
        unit = unit_of(name)
        n = int(cand.get("n") or 0)
        row_fail = False
        for stat in gated_stats(n):
            if worse(float(base[stat]), float(cand[stat]), ratio_for(stat), floor_for(name, stat)):
                row_fail = True
                failures.append(
                    f"{name} {stat} {fmt_num(float(base[stat]), unit)} -> "
                    f"{fmt_num(float(cand[stat]), unit)} "
                    f"({delta_text(float(base[stat]), float(cand[stat]), unit)}) "
                    f"exceeds {ratio_for(stat):.0%} and floor {fmt_num(floor_for(name, stat), unit)}{unit}"
                )
        if n >= 15 and worse(float(base["p99"]), float(cand["p99"]), P99_RATIO, floor_for(name, "p99")):
            p99_notes.append(name)
        mark = "FAIL" if row_fail else "ok"
        rows.append(
            "| {name} | {bmed} | {cmed} | {dmed} | {bp} | {cp} | {dp} | {mark} |".format(
                name=name,
                bmed=fmt_num(float(base["median"]), unit),
                cmed=fmt_num(float(cand["median"]), unit),
                dmed=delta_text(float(base["median"]), float(cand["median"]), unit),
                bp=fmt_num(float(base["p95"]), unit),
                cp=fmt_num(float(cand["p95"]), unit),
                dp=delta_text(float(base["p95"]), float(cand["p95"]), unit),
                mark=mark,
            )
        )
    verdict = "FAIL" if failures else "pass"
    lines = [
        "<!-- quill-bench -->",
        "",
        "## Bench",
        "",
        f"Result: **{verdict}**.",
        "",
        f"Compared `{candidate_label}` to `{baseline_label}` on the same runner. "
        "Lower is better. A gated stat fails when it is slower by more than "
        f"{RATIO:.0%} ({P99_RATIO:.0%} for p99) and the absolute delta is above its floor. "
        "p95 is gated when that side recorded at least 5 samples; p99 when it recorded at least 15. "
        "The number in the table is the median across repeated runs, not the best run.",
        "",
        f"| metric | {baseline_label} median | {candidate_label} median | median Δ | "
        f"{baseline_label} p95 | {candidate_label} p95 | p95 Δ | |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
        *rows,
        "",
    ]
    if failures:
        lines.append("Regressions:")
        lines.append("")
        for item in failures:
            lines.append(f"- {item}")
        lines.append("")
    lines.extend(noise_section(candidate, baseline, candidate_label, baseline_label))
    if p99_notes:
        lines.append("")
        lines.append("p99 also regressed for: " + ", ".join(p99_notes) + ".")
        lines.append("")
    lines.append("Thresholds live in `Scripts/bench_compare.py`. ")
    lines.append("Update recorded absolutes with `Scripts/bench.sh --update-baseline` ")
    lines.append("(the same command on CI or on Aidan's Mac). ")
    lines.append("The gate itself is the same-runner comparison, not that file.")
    lines.append("")
    return "\n".join(lines), (1 if failures else 0)


def noise_section(candidate: dict, baseline: dict, candidate_label: str, baseline_label: str) -> list[str]:
    left = baseline.get("noise") or {}
    right = candidate.get("noise") or {}
    names = sorted(set(left) | set(right))
    if not names:
        return []
    lines = [
        "### Run-to-run spread",
        "",
        "Spread is `(max - min) / median` of the per-run medians on this runner. "
        "Floors need to sit above this noise or the gate flakes.",
        "",
        f"| metric | {baseline_label} spread | {candidate_label} spread |",
        "| --- | ---: | ---: |",
    ]
    for name in names:
        lines.append(
            f"| {name} | {spread_cell(left.get(name))} | {spread_cell(right.get(name))} |"
        )
    lines.append("")
    return lines


def spread_cell(entry: dict | None) -> str:
    if not entry:
        return "—"
    ratio = float(entry.get("spreadRatio") or 0)
    spread = float(entry.get("spread") or 0)
    return f"{ratio:.1%} ({spread:.3f})"


def overlay_text(text: str) -> str:
    text = insert_call(text, "AppPerf.noteKeyWindow()", "AppBench.noteKeyWindow()")
    text = insert_call(text, "AppPerf.launchDidFinish()", "AppBench.launchDidFinish()")
    if 'env["QUILL_BENCH"]' not in text:
        old = 'env["QUILL_SMOKE"] != "1" && env["QUILL_PERF"] != "1"'
        new = old + ' && env["QUILL_BENCH"] != "1"'
        if old not in text:
            raise SystemExit("overlay: terminate check not found in QuillApp.swift")
        text = text.replace(old, new, 1)
    return text


def insert_call(text: str, existing: str, addition: str) -> str:
    if addition in text:
        return text
    idx = text.find(existing)
    if idx < 0:
        raise SystemExit(f"overlay: missing `{existing}` in QuillApp.swift")
    end = idx + len(existing)
    line_start = text.rfind("\n", 0, idx) + 1
    indent = text[line_start:idx]
    return text[:end] + "\n" + indent + addition + text[end:]


def overlay_repo(target: Path) -> None:
    source = ROOT / "Sources" / "Quill" / "AppBench.swift"
    dest_dir = target / "Sources" / "Quill"
    app = dest_dir / "QuillApp.swift"
    if not source.is_file() or not app.is_file():
        raise SystemExit(f"overlay: {target} does not look like the Quill repo")
    shutil.copyfile(source, dest_dir / "AppBench.swift")
    app.write_text(overlay_text(app.read_text(encoding="utf-8")), encoding="utf-8")
    print(f"bench overlay: {target}")


def app_bench_metrics() -> set[str]:
    text = (ROOT / "Sources" / "Quill" / "AppBench.swift").read_text(encoding="utf-8")
    return set(ADD_CALL.findall(text))


def self_test() -> int:
    failed = False

    def check(cond: bool, message: str) -> None:
        nonlocal failed
        if cond:
            print(f"self-test: {message}")
        else:
            print(f"self-test: FAIL {message}", file=sys.stderr)
            failed = True

    names = app_bench_metrics()
    check(names == set(FLOORS), "AppBench metrics match the floor table")
    if names != set(FLOORS):
        print(f"  only in AppBench: {sorted(names - set(FLOORS))}", file=sys.stderr)
        print(f"  only in floors: {sorted(set(FLOORS) - names)}", file=sys.stderr)

    cycle = "\n".join(markdown_cycle())
    for shape in ("# ", "| --- |", "- ", "](", "[[", "```"):
        check(shape in cycle, f"fixture cycle contains {shape!r}")
    check(PROSE_LINES["prose-1k.md"] >= 1000, "1k fixture")
    check(PROSE_LINES["prose-50k.md"] >= 50_000, "50k fixture")
    check(PROSE_LINES["prose-500k.md"] >= 500_000, "500k fixture")
    check(HEAVY_LINES >= 1000, "heavy fixture")
    check(NOTE_COUNT >= 1000, "picker repo has at least 1000 notes")
    check(WIDE_COUNT >= 200, "directory fixture has at least 200 entries")

    with tempfile.TemporaryDirectory() as tmp:
        sample = Path(tmp) / "sample.md"
        write_markdown(sample, 40)
        body = sample.read_text(encoding="utf-8")
        check(body.endswith("<!-- quill-bench-end -->\n"), "end marker")
        check(body.count("\n") == 40, "line count")
        check("Heading" in body and "| --- |" in body and "```swift" in body, "sample shapes")

        base = {
            "metrics": {"open1kMs": {"median": 100.0, "p95": 110.0, "p99": 120.0, "n": 10}},
            "noise": {"open1kMs": {"spread": 2.0, "spreadRatio": 0.02}},
        }
        mild = {
            "metrics": {"open1kMs": {"median": 110.0, "p95": 112.0, "p99": 121.0, "n": 10}},
        }
        text, code = compare_docs(mild, base, "pr", "base")
        check(code == 0 and "FAIL" not in text.split("Regressions")[0], "10% slower is inside 15%")

        small_abs = {
            "metrics": {"keyInsertTopMs": {"median": 0.30, "p95": 0.32, "p99": 0.40, "n": 20}},
        }
        small_base = {
            "metrics": {"keyInsertTopMs": {"median": 0.23, "p95": 0.25, "p99": 0.30, "n": 20}},
        }
        _, code = compare_docs(small_abs, small_base, "pr", "base")
        check(code == 0, "30% of a sub-millisecond keystroke stays under the floor")

        big = {
            "metrics": {"open1kMs": {"median": 130.0, "p95": 140.0, "p99": 150.0, "n": 10}},
        }
        _, code = compare_docs(big, base, "pr", "base")
        check(code == 1, "30% and above the floor fails")

        faster = {
            "metrics": {"open1kMs": {"median": 70.0, "p95": 80.0, "p99": 90.0, "n": 10}},
        }
        _, code = compare_docs(faster, base, "pr", "base")
        check(code == 0, "a faster median passes")

        missing = {"metrics": {}}
        _, code = compare_docs(missing, base, "pr", "base")
        check(code == 1, "a dropped metric fails")

        p99_only = {
            "metrics": {"open1kMs": {"median": 100.0, "p95": 110.0, "p99": 400.0, "n": 10}},
        }
        _, code = compare_docs(p99_only, base, "pr", "base")
        check(code == 0, "p99 is not gated below 15 samples")

        key_base = {
            "metrics": {"keyInsertTopMs": {"median": 1.0, "p95": 1.1, "p99": 1.2, "n": 20}},
        }
        key_bad = {
            "metrics": {"keyInsertTopMs": {"median": 1.05, "p95": 1.1, "p99": 20.0, "n": 20}},
        }
        _, code = compare_docs(key_bad, key_base, "pr", "base")
        check(code == 1, "p99 is gated once a run has 15 samples")

        pooled = aggregate_payloads(
            [
                {"metrics": {"launchToKeyMs": {"median": 10.0, "p95": 10.0, "p99": 10.0, "n": 1}}},
                {"metrics": {"launchToKeyMs": {"median": 30.0, "p95": 30.0, "p99": 30.0, "n": 1}}},
                {"metrics": {"launchToKeyMs": {"median": 20.0, "p95": 20.0, "p99": 20.0, "n": 1}}},
            ]
        )
        check(abs(pooled["metrics"]["launchToKeyMs"]["median"] - 20.0) < 1e-9, "aggregate uses the median, not the best run")

        snippet = (
            "                    AppPerf.noteKeyWindow()\n"
            "        AppPerf.launchDidFinish()\n"
            '        return env["QUILL_SMOKE"] != "1" && env["QUILL_PERF"] != "1"\n'
        )
        patched = overlay_text(snippet)
        check(patched.count("AppBench.noteKeyWindow()") == 1, "overlay inserts the key-window hook")
        check(patched.count("AppBench.launchDidFinish()") == 1, "overlay inserts the launch hook")
        check('env["QUILL_BENCH"]' in patched, "overlay keeps the bench process alive")
        check(overlay_text(patched) == patched, "overlay is idempotent")

    source = Path(__file__).read_text(encoding="utf-8")
    imports = set(IMPORT_LINE.findall(source))
    check(imports <= ALLOWED_IMPORTS, "bench script stays on the Python stdlib")
    bench_sh = (ROOT / "Scripts" / "bench.sh").read_text(encoding="utf-8")
    check("set -euo pipefail" in bench_sh, "bench.sh is strict bash")
    check("QUILL_BENCH" in bench_sh and "--update-baseline" in bench_sh, "bench.sh runs the suite and can record a baseline")
    app = (ROOT / "Sources" / "Quill" / "AppBench.swift").read_text(encoding="utf-8")
    for token in ("KeyEvent", "consumeScroll", "prose-500k.md", "quill-bench-end", "findFiles", "liveGrep"):
        check(token in app, f"AppBench drives {token}")

    if failed:
        return 1
    print("bench_compare: self-test passed")
    return 0


def aggregate_payloads(docs: list[dict]) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        folder = Path(tmp)
        for index, doc in enumerate(docs):
            (folder / f"run-{index}.json").write_text(json.dumps(doc), encoding="utf-8")
        return aggregate_dir(folder)


def cmd_fixtures(args: argparse.Namespace) -> int:
    write_fixtures(Path(args.dir), quick=args.quick)
    return 0


def cmd_overlay(args: argparse.Namespace) -> int:
    overlay_repo(Path(args.repo))
    return 0


def cmd_aggregate(args: argparse.Namespace) -> int:
    doc = aggregate_dir(Path(args.dir))
    write_json(Path(args.out), doc)
    print(f"bench aggregate: {args.out}")
    return 0


def cmd_compare(args: argparse.Namespace) -> int:
    candidate = json.loads(Path(args.candidate).read_text(encoding="utf-8"))
    baseline_path = Path(args.baseline)
    if baseline_path.is_file():
        baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    else:
        baseline = {"metrics": {}}
    if args.allow_empty_baseline and not (baseline.get("metrics") or {}):
        text = (
            "<!-- quill-bench -->\n\n## Bench\n\n"
            "The committed baseline has no measurements yet. "
            "Record one with `Scripts/bench.sh --update-baseline`.\n"
        )
        publish(text, args)
        print("bench compare: baseline is empty; recorded nothing to fail on")
        return 0
    text, code = compare_docs(candidate, baseline, args.candidate_label, args.baseline_label)
    publish(text, args)
    print(text)
    return code


def publish(text: str, args: argparse.Namespace) -> None:
    if args.markdown:
        path = Path(args.markdown)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    if args.summary:
        summary = Path(args.summary)
        with summary.open("a", encoding="utf-8") as handle:
            handle.write("\n")
            handle.write(text)
            handle.write("\n")


def cmd_update_baseline(args: argparse.Namespace) -> int:
    result = json.loads(Path(args.result).read_text(encoding="utf-8"))
    doc = {
        "version": 1,
        "lowerIsBetter": True,
        "note": (
            "Absolute medians from one machine. The PR gate does not fail on this file. "
            "It builds this commit and the base commit on the same runner and compares those. "
            "Refresh this file with Scripts/bench.sh --update-baseline on the machine whose "
            "numbers you want to keep (macos CI, or Aidan's Mac)."
        ),
        "recordedFrom": result.get("host"),
        "sha": result.get("sha") or "",
        "metrics": result.get("metrics") or {},
        "noise": result.get("noise") or {},
    }
    write_json(Path(args.baseline), doc)
    print(f"bench baseline: wrote {args.baseline}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bench_compare.py")
    sub = parser.add_subparsers(dest="cmd", required=True)

    fixtures = sub.add_parser("fixtures")
    fixtures.add_argument("--dir", required=True)
    fixtures.add_argument("--quick", action="store_true")
    fixtures.set_defaults(func=cmd_fixtures)

    overlay = sub.add_parser("overlay")
    overlay.add_argument("--repo", required=True)
    overlay.set_defaults(func=cmd_overlay)

    aggregate = sub.add_parser("aggregate")
    aggregate.add_argument("--dir", required=True)
    aggregate.add_argument("--out", required=True)
    aggregate.set_defaults(func=cmd_aggregate)

    compare = sub.add_parser("compare")
    compare.add_argument("--candidate", required=True)
    compare.add_argument("--baseline", required=True)
    compare.add_argument("--candidate-label", default="PR")
    compare.add_argument("--baseline-label", default="base")
    compare.add_argument("--markdown", default="")
    compare.add_argument("--summary", default="")
    compare.add_argument("--allow-empty-baseline", action="store_true")
    compare.set_defaults(func=cmd_compare)

    update = sub.add_parser("update-baseline")
    update.add_argument("--result", required=True)
    update.add_argument("--baseline", required=True)
    update.set_defaults(func=cmd_update_baseline)
    return parser


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return self_test()
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
