#!/bin/zsh
set -euo pipefail

# Builds a locally installable app bundle.  Prefer a stable Apple Development
# identity when Xcode has one: Keychain's “Always Allow” permission is attached
# to the signing requirement, while an ad-hoc signature changes whenever the
# executable changes and can trigger the password dialog again.
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

# CODESIGN_IDENTITY may be set explicitly for a team or distribution build.
# Otherwise choose the first locally available Apple Development certificate.
identity="${CODESIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/{print $2; exit}')"
fi

if [[ -n "$identity" ]]; then
  codesign --force --sign "$identity" --entitlements "Sources/KeyboardWtfApp/Resources/keyboard.wtf.entitlements" "$app"
  echo "Signed with stable development identity: $identity"
else
  codesign --force --sign - --entitlements "Sources/KeyboardWtfApp/Resources/keyboard.wtf.entitlements" "$app"
  echo "Warning: no Apple Development signing identity found; the first Keychain migration may ask once, then the app uses its local cache on later launches."
fi
codesign --verify --deep --strict --verbose=2 "$app"
echo "$app"
