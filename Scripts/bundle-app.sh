#!/usr/bin/env bash
# Build the macOS executable with SwiftPM and wrap it in Quill.app.
# A failed or skipped rebuild must not package the previous binary: smoke would
# then pass against old code.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "bundle-app: swift build -c release --product Quill" >&2
set +e
swift build -c release --product Quill -Xswiftc -strict-concurrency=complete
build_status=$?
set -e
if [[ "$build_status" -ne 0 ]]; then
  echo "bundle-app: swift build failed (exit ${build_status}); refusing to package a previous binary" >&2
  exit "$build_status"
fi

bin_dir="$(swift build -c release --product Quill -Xswiftc -strict-concurrency=complete --show-bin-path)"
BIN="${bin_dir}/Quill"
if [[ ! -x "$BIN" ]]; then
  echo "bundle-app: build reported success but the binary is missing: ${BIN}" >&2
  exit 1
fi

# macOS stat. The product must not be older than the Swift sources it compiles.
binary_mtime="$(stat -f %m "$BIN")"
stale=""
while IFS= read -r -d '' path; do
  source_mtime="$(stat -f %m "$path")"
  if [[ "$binary_mtime" -lt "$source_mtime" ]]; then
    echo "bundle-app: ${BIN} (${binary_mtime}) is older than ${path} (${source_mtime})" >&2
    stale=1
  fi
done < <(find Sources Package.swift -name '*.swift' -print0)
if [[ -n "$stale" ]]; then
  echo "bundle-app: refusing to package a stale binary" >&2
  exit 1
fi

DEST="${1:-dist/Quill.app}"
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$BIN" "$DEST/Contents/MacOS/Quill"
cp Sources/Quill/Info.plist "$DEST/Contents/Info.plist"
icon_src="Resources/AppIcon.icns"
if [[ ! -s "$icon_src" ]]; then
  echo "bundle-app: missing ${icon_src}; run python3 Scripts/make-icon.py" >&2
  exit 1
fi
cp "$icon_src" "$DEST/Contents/Resources/AppIcon.icns"
icon="$DEST/Contents/Resources/AppIcon.icns"
if [[ ! -s "$icon" ]]; then
  echo "bundle-app: AppIcon.icns missing from ${DEST}" >&2
  exit 1
fi
magic="$(head -c 4 "$icon")"
if [[ "$magic" != "icns" ]]; then
  echo "bundle-app: AppIcon.icns is not an icns file" >&2
  exit 1
fi
if ! grep -q "<key>CFBundleIconFile</key>" "$DEST/Contents/Info.plist" \
  || ! grep -q "<key>CFBundleIconName</key>" "$DEST/Contents/Info.plist"; then
  echo "bundle-app: Info.plist is missing CFBundleIconFile or CFBundleIconName" >&2
  exit 1
fi
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$DEST"
fi
echo "Built $DEST"
echo "Open with: open $DEST"
echo "Install with: ./Scripts/install.sh"
