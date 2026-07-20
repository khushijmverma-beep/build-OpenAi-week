# Test report

## Implemented checks

`Tests/KeyboardWtfCoreTests` covers phase/tone mapping, confirmation expiry, key redaction, Responses output parsing, and SQLite memory/workflow persistence. `Scripts/scan-secrets.sh` is suitable for local and CI secret scans.

Expected verification commands on an Xcode 16/macOS 14 machine:

```bash
bash Scripts/scan-secrets.sh
swift build -c debug
swift test
swift build -c release
bash Scripts/generate-project.sh
xcodebuild -project keyboard.wtf.xcodeproj -scheme keyboard.wtf -configuration Release archive -archivePath build/keyboard.wtf.xcarchive
```

## Actual result in this build session

`swift build -v` was attempted and could not load `PackageDescription` from the active Command Line Tools Swift 5.7 installation. `xcodebuild` also reports that the active developer directory is CommandLineTools, not Xcode. The machine is macOS 12.5 and does not meet the app’s macOS 14/Xcode 16 validation target.

As a constrained fallback, all core source files were type-checked together against the installed macOS frameworks, emitted as a temporary `KeyboardWtfCore` module, and the app shell was type-checked against that module. A runtime smoke check passed for semantic state/redaction and another passed for temporary SQLite memory persistence. Plist/entitlement lint, secret scanning, and whitespace checks passed. These are source-level checks, not a SwiftPM/Xcode build or a native `.app` run. No archive, UI, microphone, Accessibility, hotkey, camera, screen, signing, or live OpenAI test is claimed.

There is no `OPENAI_API_KEY` in the environment, so no paid live request was attempted.
