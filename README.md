# keyboard.wtf for macOS

Voice-first control for the personal Mac. `keyboard.wtf` is a native menu-bar app with three deliberate modes:

- **Dictation** captures speech locally and inserts literal text without calling OpenAI.
- **Smart Writing** turns rough speech into ready-to-send text through the OpenAI Responses API.
- **Jarvis** is a low-latency OpenAI Realtime conversation with typed, receipt-backed macOS tools.

The app is designed for macOS 14+, Swift 6, SwiftUI, AppKit, AVFoundation, Accessibility APIs, Keychain, and SQLite. It has no other model provider.

## Quick start

1. Use macOS 14 or later on Apple silicon with Xcode 16 and select it with `xcode-select`.
2. From this folder run `./Scripts/install-app.sh` to build, sign, install, and launch the menu-bar app. If no Apple Development identity is available, the script uses an ad-hoc signature and macOS permissions may need to be re-approved after rebuilding.
3. Open Settings from the menu-bar item (or press Control + Option + J), add an OpenAI API key, then grant microphone, Accessibility, and Screen Recording permissions as needed.

The key is saved in the macOS Keychain and cached locally after the one-time migration so ad-hoc rebuilds do not repeatedly prompt. `OPENAI_API_KEY` is supported only for development and CI. Copy `.env.example`; never commit `.env`.

## Default shortcuts

| Mode | Shortcut |
| --- | --- |
| Dictation | Control + Option + D |
| Smart Writing | Control + Option + K |
| Jarvis | Control + Option + Q |
| Cancel | Control + Option + X |
| Settings | Control + Option + J |

Pressing a Dictation or Smart Writing shortcut again finishes its turn. Cancel stops microphone capture, local recognition, OpenAI activity, playback, and pending actions.

## OpenAI model routing

- `gpt-realtime-2.1` for live Jarvis audio conversations.
- `gpt-5.4-mini` for routine Smart Writing and ordinary Responses requests.
- `gpt-5.6-terra` is retained only as a configurable escalation model.

See [OPENAI_INTEGRATION.md](OPENAI_INTEGRATION.md) for the transport and safety design.

## Privacy and permissions

Dictation uses a local-only macOS speech recognizer and refuses remote speech recognition. Smart Writing sends only its explicit transcript to OpenAI. Jarvis streams only the audio from an active conversation. Selected text, screenshots, and camera content are only captured after an explicit invocation; none are automatically written to memory. Details: [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md).

## Current verification status

The current Apple-silicon Mac build has passed the deterministic Swift suite (10 tests, 0 failures), a live Responses API smoke test, a live Realtime WebSocket tool round-trip, a production release build, code-signature verification, ZIP extraction/listing, and a packaged `.app` launch. A stable Apple Development identity is not installed on this Mac, so the release artifact is ad-hoc signed and macOS may ask for Keychain or privacy permissions again after rebuilding. Microphone capture, Accessibility actions, Screen Recording, camera capture, Spotify Apple Events, and launch-at-login still require approval and hands-on verification on the Mac.

## Documentation

- [Build Week scope and Windows reference map](BUILD_WEEK_SCOPE.md)
- [Architecture](ARCHITECTURE.md)
- [OpenAI integration](OPENAI_INTEGRATION.md)
- [Demo script](DEMO_SCRIPT.md)
- [Submission copy](SUBMISSION_COPY.md)
