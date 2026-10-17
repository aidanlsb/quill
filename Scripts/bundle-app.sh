#!/usr/bin/env bash
# Build the macOS executable with SwiftPM and wrap it in Quill.app.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Quill -Xswiftc -strict-concurrency=complete
BIN="$(swift build -c release --product Quill -Xswiftc -strict-concurrency=complete --show-bin-path)/Quill"
DEST="${1:-dist/Quill.app}"
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$BIN" "$DEST/Contents/MacOS/Quill"
cp Sources/Quill/Info.plist "$DEST/Contents/Info.plist"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$DEST"
fi
echo "Built $DEST"
echo "Open with: open $DEST"
echo "Install with: ./Scripts/install.sh"
