#!/bin/zsh
set -euo pipefail

# Builds a locally installable, ad-hoc-signed app bundle without requiring a paid
# signing identity. This is intentionally a development distribution, not a notarized release.
root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-debug}"
cd "$root"

swift build -c "$configuration"
bin_path="$(swift build -c "$configuration" --show-bin-path)"
app="$root/dist/keyboard.wtf.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/keyboard-wtf" "$app/Contents/MacOS/keyboard.wtf"
cp "Sources/KeyboardWtfApp/Resources/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.yourname.keyboardwtf" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string keyboard.wtf" "$app/Contents/Info.plist"
codesign --force --sign - --entitlements "Sources/KeyboardWtfApp/Resources/keyboard.wtf.entitlements" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
echo "$app"
