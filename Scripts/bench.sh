#!/usr/bin/env bash
# Run the Quill performance suite.
# Local:  Scripts/bench.sh
# Record: Scripts/bench.sh --update-baseline
# CI:     Scripts/bench.sh ci --bin PATH --base-ref main --pr N
# See CONTRIBUTING.md. The same command is what to run on Aidan's Mac.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

launch_runs=5
suite_runs=3
out="$root/artifacts/bench/result.json"
bin=""
quick=0
cmd="run"
base_ref=""
pr=""
update=0
bench_work=""

usage() {
  echo "usage: Scripts/bench.sh [--bin PATH] [--out FILE] [--launch-runs N] [--suite-runs N] [--quick] [--update-baseline]" >&2
  echo "       Scripts/bench.sh doctor [--bin PATH]" >&2
  echo "       Scripts/bench.sh ci --bin PATH --base-ref REF [--pr N]" >&2
}

cleanup() {
  if [[ -n "$bench_work" ]]; then
    git worktree remove --force "$bench_work" >/dev/null 2>&1 || true
    rm -rf "$(dirname "$bench_work")"
  fi
}
trap cleanup EXIT

require_darwin() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "bench: Quill is an AppKit app. This host ($(uname -s)) cannot launch it." >&2
    echo "bench: run Scripts/bench.sh on macOS. The macos CI job runs the gate." >&2
    exit 1
  fi
  if ! command -v swift >/dev/null 2>&1; then
    echo "bench: swift is not on PATH" >&2
    exit 1
  fi
}

# Bash 3.2 does not abort on a failing assignment, so the build runs in the
# current shell and writes the product path to a file. Compiler output stays
# in the log instead of being swallowed by a command substitution.
swift_release_bin() {
  local package="$1"
  local log="$2"
  local pathfile="$3"
  local status=0
  mkdir -p "$(dirname "$log")" "$(dirname "$pathfile")"
  set +e
  swift build -c release --product Quill -Xswiftc -strict-concurrency=complete --package-path "$package" >"$log" 2>&1
  status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    echo "bench: swift build failed ($status). Log: $log" >&2
    cat "$log" >&2
    exit "$status"
  fi
  local shown
  set +e
  shown="$(swift build -c release --product Quill -Xswiftc -strict-concurrency=complete --package-path "$package" --show-bin-path 2>>"$log")"
  status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    echo "bench: show-bin-path failed ($status). Log: $log" >&2
    cat "$log" >&2
    exit "$status"
  fi
  shown="$(printf '%s\n' "$shown" | tail -n 1)"
  local product="${shown}/Quill"
  if [[ ! -x "$product" ]]; then
    echo "bench: binary is not executable: $product" >&2
    echo "bench: build log follows" >&2
    cat "$log" >&2
    exit 1
  fi
  printf '%s\n' "$product" >"$pathfile"
}

ensure_bin() {
  if [[ -n "$bin" ]]; then
    if [[ ! -x "$bin" ]]; then
      echo "bench: binary is not executable: $bin" >&2
      exit 1
    fi
    return
  fi
  echo "bench: building release Quill"
  local pathfile="$root/artifacts/bench/bin-path.txt"
  swift_release_bin "$root" "$root/artifacts/bench/build.log" "$pathfile"
  bin="$(cat "$pathfile")"
}

wait_pid() {
  local pid="$1"
  local limit="$2"
  local log="$3"
  local i=0
  local status=0
  local finished=0
  while [[ "$i" -lt "$limit" ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      set +e
      wait "$pid"
      status=$?
      set -e
      finished=1
      break
    fi
    sleep 1
    i=$((i + 1))
  done
  if [[ "$finished" -eq 0 ]]; then
    echo "bench: still running after ${limit}s; killing pid $pid" >&2
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    cat "$log" >&2 || true
    exit 1
  fi
  if [[ "$status" -ne 0 ]]; then
    echo "bench: failed (status $status). Log: $log" >&2
    cat "$log" >&2 || true
    exit "$status"
  fi
}

run_app() {
  local app="$1"
  local dest="$2"
  local phase="$3"
  local fixtures="$4"
  local limit="$5"
  local log="${dest}.log"
  mkdir -p "$(dirname "$dest")"
  : > "$log"
  if [[ "$phase" == "suite" ]]; then
    SWIFT_BACKTRACE=enable \
      QUILL_BENCH=1 \
      QUILL_BENCH_PHASE=suite \
      QUILL_BENCH_OUT="$dest" \
      QUILL_BENCH_FIXTURES="$fixtures" \
      QUILL_BENCH_SHA="${QUILL_BENCH_SHA:-}" \
      QUILL_BENCH_QUICK="${QUILL_BENCH_QUICK:-}" \
      "$app" >"$log" 2>&1 &
  else
    QUILL_BENCH=1 \
      QUILL_BENCH_PHASE=launch \
      QUILL_BENCH_OUT="$dest" \
      QUILL_BENCH_SHA="${QUILL_BENCH_SHA:-}" \
      "$app" >"$log" 2>&1 &
  fi
  local pid=$!
  wait_pid "$pid" "$limit" "$log"
  if ! grep -F -q "quill bench done" "$log"; then
    echo "bench: exited without 'quill bench done'. Log: $log" >&2
    cat "$log" >&2 || true
    exit 1
  fi
  if [[ ! -s "$dest" ]]; then
    echo "bench: missing $dest" >&2
    exit 1
  fi
  grep -F "quill bench " "$log" || true
}

run_many() {
  local app="$1"
  local fixtures="$2"
  local dest="$3"
  if [[ "$quick" -eq 0 ]]; then
    echo "bench: warmup suite (discarded)"
    run_app "$app" "$dest/warmup.json" suite "$fixtures" 1260
    rm -f "$dest/warmup.json" "$dest/warmup.json.log"
  fi
  local i=1
  while [[ "$i" -le "$launch_runs" ]]; do
    echo "bench: launch ${i}/${launch_runs}"
    run_app "$app" "$dest/launch-${i}.json" launch "$fixtures" 60
    i=$((i + 1))
  done
  # The first suite processes after a cold runner step down by tens of
  # milliseconds (keyNormalTop was 402, 366, then 305). Drop two more
  # suites once the launches are done so the measured median sits on the
  # flat part. Base is measured second and was already flat.
  if [[ "$quick" -eq 0 ]]; then
    i=1
    while [[ "$i" -le 2 ]]; do
      echo "bench: settle suite ${i}/2 (discarded)"
      run_app "$app" "$dest/settle-${i}.json" suite "$fixtures" 1260
      rm -f "$dest/settle-${i}.json" "$dest/settle-${i}.json.log"
      i=$((i + 1))
    done
  fi
  i=1
  while [[ "$i" -le "$suite_runs" ]]; do
    echo "bench: suite ${i}/${suite_runs}"
    run_app "$app" "$dest/suite-${i}.json" suite "$fixtures" 1260
    i=$((i + 1))
  done
}

prepare_fixtures() {
  local fix="$root/artifacts/bench/fixtures"
  if [[ "$quick" -eq 1 ]]; then
    QUILL_BENCH_QUICK=1
    export QUILL_BENCH_QUICK
    python3 "$root/Scripts/bench_compare.py" fixtures --dir "$fix" --quick
    launch_runs=1
    suite_runs=1
  else
    unset QUILL_BENCH_QUICK || true
    python3 "$root/Scripts/bench_compare.py" fixtures --dir "$fix"
  fi
}

post_comment() {
  local number="$1"
  local file="$2"
  local repo="${GITHUB_REPOSITORY:-}"
  if [[ -z "$number" || -z "$repo" || -z "${GH_TOKEN:-}" ]]; then
    echo "bench: skipping PR comment"
    return 0
  fi
  local marker="<!-- quill-bench -->"
  local existing
  existing="$(gh api "repos/${repo}/issues/${number}/comments" --jq "[.[] | select(.body | contains(\"${marker}\"))][0].id // empty")"
  if [[ -n "$existing" ]]; then
    gh api -X PATCH "repos/${repo}/issues/comments/${existing}" -f body="$(cat "$file")" >/dev/null
  else
    gh pr comment "$number" --body-file "$file" >/dev/null
  fi
  echo "bench: updated PR comment"
}

cmd_doctor() {
  require_darwin
  local swift_line
  swift_line="$(swift --version)"
  swift_line="${swift_line%%$'\n'*}"
  echo "bench: $swift_line"
  if [[ -z "$bin" ]]; then
    echo "bench: no --bin; a later run will build the release Quill"
    exit 0
  fi
  if [[ ! -x "$bin" ]]; then
    echo "bench: binary is not executable: $bin" >&2
    exit 1
  fi
  echo "bench: binary $bin"
}

cmd_run() {
  require_darwin
  ensure_bin
  local sha
  sha="$(git rev-parse HEAD)"
  QUILL_BENCH_SHA="$sha"
  export QUILL_BENCH_SHA
  prepare_fixtures
  local runs="$root/artifacts/bench/runs"
  rm -rf "$runs"
  mkdir -p "$runs"
  run_many "$bin" "$root/artifacts/bench/fixtures" "$runs"
  python3 "$root/Scripts/bench_compare.py" aggregate --dir "$runs" --out "$out"
  if [[ "$update" -eq 1 ]]; then
    python3 "$root/Scripts/bench_compare.py" update-baseline --result "$out" --baseline "$root/Baselines/perf-macos.json"
    python3 "$root/Scripts/bench_compare.py" compare \
      --candidate "$out" \
      --baseline "$root/Baselines/perf-macos.json" \
      --candidate-label "this run" \
      --baseline-label "baseline" \
      --markdown "$root/artifacts/bench/compare.md" \
      --allow-empty-baseline || true
    echo "bench: updated Baselines/perf-macos.json"
    exit 0
  fi
  python3 "$root/Scripts/bench_compare.py" compare \
    --candidate "$out" \
    --baseline "$root/Baselines/perf-macos.json" \
    --candidate-label "this run" \
    --baseline-label "baseline" \
    --markdown "$root/artifacts/bench/compare.md" \
    --allow-empty-baseline
  echo "bench: $out"
}

cmd_ci() {
  require_darwin
  if [[ -z "$bin" || -z "$base_ref" ]]; then
    usage
    exit 2
  fi
  if [[ ! -x "$bin" ]]; then
    echo "bench: binary is not executable: $bin" >&2
    exit 1
  fi
  unset QUILL_BENCH_QUICK || true
  quick=0
  local sha
  sha="$(git rev-parse HEAD)"
  QUILL_BENCH_SHA="$sha"
  export QUILL_BENCH_SHA
  prepare_fixtures
  local pr_runs="$root/artifacts/bench/pr-runs"
  rm -rf "$pr_runs"
  mkdir -p "$pr_runs"
  echo "bench: measuring PR $sha"
  run_many "$bin" "$root/artifacts/bench/fixtures" "$pr_runs"
  python3 "$root/Scripts/bench_compare.py" aggregate --dir "$pr_runs" --out "$root/artifacts/bench/pr.json"

  echo "bench: fetching origin/${base_ref}"
  git fetch --no-tags origin "refs/heads/${base_ref}:refs/remotes/origin/${base_ref}"
  local base_sha parent
  base_sha="$(git rev-parse "origin/${base_ref}")"
  parent="$(mktemp -d /tmp/quill-bench-base.XXXXXX)"
  bench_work="${parent}/src"
  git worktree add --detach "$bench_work" "$base_sha"
  python3 "$root/Scripts/bench_compare.py" overlay --repo "$bench_work"
  echo "bench: building base $base_sha"
  local base_bin pathfile
  pathfile="$root/artifacts/bench/base-bin-path.txt"
  swift_release_bin "$bench_work" "$root/artifacts/bench/base-build.log" "$pathfile"
  base_bin="$(cat "$pathfile")"
  QUILL_BENCH_SHA="$base_sha"
  export QUILL_BENCH_SHA
  local base_runs="$root/artifacts/bench/base-runs"
  rm -rf "$base_runs"
  mkdir -p "$base_runs"
  echo "bench: measuring base $base_sha"
  run_many "$base_bin" "$root/artifacts/bench/fixtures" "$base_runs"
  python3 "$root/Scripts/bench_compare.py" aggregate --dir "$base_runs" --out "$root/artifacts/bench/base.json"

  if [[ -z "$pr" && -n "${GH_TOKEN:-}" ]]; then
    pr="$(gh pr view --json number -q .number 2>/dev/null || true)"
  fi
  local status=0
  set +e
  python3 "$root/Scripts/bench_compare.py" compare \
    --candidate "$root/artifacts/bench/pr.json" \
    --baseline "$root/artifacts/bench/base.json" \
    --candidate-label "PR ${sha}" \
    --baseline-label "base ${base_sha}" \
    --markdown "$root/artifacts/bench/comment.md" \
    --summary "${GITHUB_STEP_SUMMARY:-}"
  status=$?
  set -e
  post_comment "$pr" "$root/artifacts/bench/comment.md" || echo "bench: PR comment failed" >&2
  exit "$status"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    doctor)
      cmd="doctor"
      shift
      ;;
    ci)
      cmd="ci"
      shift
      ;;
    --bin)
      bin="${2:-}"
      if [[ -z "$bin" ]]; then
        usage
        exit 2
      fi
      shift 2
      ;;
    --out)
      out="${2:-}"
      if [[ -z "$out" ]]; then
        usage
        exit 2
      fi
      shift 2
      ;;
    --launch-runs)
      launch_runs="${2:-}"
      shift 2
      ;;
    --suite-runs)
      suite_runs="${2:-}"
      shift 2
      ;;
    --quick)
      quick=1
      shift
      ;;
    --update-baseline)
      update=1
      shift
      ;;
    --base-ref)
      base_ref="${2:-}"
      if [[ -z "$base_ref" ]]; then
        usage
        exit 2
      fi
      shift 2
      ;;
    --pr)
      pr="${2:-}"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$cmd" in
  doctor) cmd_doctor ;;
  ci) cmd_ci ;;
  run) cmd_run ;;
esac
