#!/bin/zsh
set -euo pipefail

# Installs the current signed build in the user's Applications folder. Launching
# it once registers the default Launch at Login setting with macOS.
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/Scripts/build-app.sh" release
destination="$HOME/Applications/keyboard.wtf.app"
mkdir -p "$HOME/Applications"
pkill -f "$root/.build/.*/keyboard-wtf" 2>/dev/null || true
pkill -f "$destination/Contents/MacOS/keyboard.wtf" 2>/dev/null || true
rm -rf "$destination"
ditto "$root/dist/keyboard.wtf.app" "$destination"
# Launch as a fresh menu-bar agent. `-n` avoids LaunchServices returning
# -600 when the previous ad-hoc-signed instance was just replaced.
open -n "$destination"
echo "Installed and launched: $destination"
