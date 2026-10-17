#!/usr/bin/env bash
# Prove Swift 6 still rejects the historical AppSmoke mutable static.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
bad="$root/Scripts/fixtures/mutable-global-bad.swift"
good="$root/Scripts/fixtures/mutable-global-good.swift"
err="$(mktemp)"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "check-concurrency-fixture: swiftc is not on PATH" >&2
  exit 1
fi

if swiftc -swift-version 6 -strict-concurrency=complete -typecheck "$bad" >"$err" 2>&1; then
  echo "check-concurrency-fixture: the historical mutable static compiled" >&2
  cat "$err" >&2 || true
  exit 1
fi

if ! grep -F -q "not concurrency-safe" "$err"; then
  echo "check-concurrency-fixture: compiler did not report the historical error" >&2
  cat "$err" >&2 || true
  exit 1
fi

if ! swiftc -swift-version 6 -strict-concurrency=complete -typecheck "$good" >"$err" 2>&1; then
  echo "check-concurrency-fixture: @MainActor static was rejected" >&2
  cat "$err" >&2 || true
  exit 1
fi

echo "check-concurrency-fixture: historical mutable static is rejected; @MainActor static typechecks"
