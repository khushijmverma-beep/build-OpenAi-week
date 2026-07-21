#!/bin/zsh
set -euo pipefail

# Installs the current signed build in the user's Applications folder. Launching
# it once registers the default Launch at Login setting with macOS.
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/Scripts/build-app.sh" release
destination="$HOME/Applications/keyboard.wtf.app"
mkdir -p "$HOME/Applications"
rm -rf "$destination"
ditto "$root/dist/keyboard.wtf.app" "$destination"
open -n "$destination"
echo "Installed and launched: $destination"
