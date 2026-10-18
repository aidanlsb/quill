#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -d dist/Quill.app ]]; then
  ./Scripts/bundle-app.sh
fi

rm -rf /Applications/Quill.app
cp -R dist/Quill.app /Applications/Quill.app
mkdir -p /usr/local/bin
cp Scripts/quill /usr/local/bin/quill
chmod +x /usr/local/bin/quill
echo "Installed /Applications/Quill.app and /usr/local/bin/quill"
echo "Try: quill ."
echo "Config (optional): ~/.config/quill/config.toml"
