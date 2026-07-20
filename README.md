# keyboard.wtf for macOS

Voice-first control for the personal Mac. `keyboard.wtf` is a native menu-bar app with three deliberate modes:

- **Dictation** captures speech locally and inserts literal text without calling OpenAI.
- **Smart Writing** turns rough speech into ready-to-send text through the OpenAI Responses API.
- **Jarvis** is a low-latency OpenAI Realtime conversation with typed, receipt-backed macOS tools.

The app is designed for macOS 14+, Swift 6, SwiftUI, AppKit, AVFoundation, Accessibility APIs, Keychain, and SQLite. It has no other model provider.

## Quick start

1. Install Xcode 16 and select it with `xcode-select`.
2. Open this folder in Xcode as a Swift package, or generate an app project with `brew install xcodegen && bash Scripts/generate-project.sh`.
3. Run `keyboard.wtf`.
4. Open Settings, add an OpenAI API key, then grant microphone and Accessibility permissions as needed.

The key is saved in the macOS Keychain. `OPENAI_API_KEY` is supported only for development and CI. Copy `.env.example`; never commit `.env`.

## Default shortcuts

| Mode | Shortcut |
| --- | --- |
| Dictation | Control + Option + D |
| Smart Writing | Control + Option + K |
| Jarvis | Control + Option + Q |
| Cancel | Control + Option + X |
| Settings | Control + Option + , |

Pressing a Dictation or Smart Writing shortcut again finishes its turn. Cancel stops microphone capture, local recognition, OpenAI activity, playback, and pending actions.

## OpenAI model routing

- `gpt-realtime-2.1` for live Jarvis audio conversations.
- `gpt-5.4-mini` for routine Smart Writing and ordinary Responses requests.
- `gpt-5.6-terra` is retained only as a configurable escalation model.

See [OPENAI_INTEGRATION.md](OPENAI_INTEGRATION.md) for the transport and safety design.

## Privacy and permissions

Dictation uses a local-only macOS speech recognizer and refuses remote speech recognition. Smart Writing sends only its explicit transcript to OpenAI. Jarvis streams only the audio from an active conversation. Selected text, screenshots, and camera content are only captured after an explicit invocation; none are automatically written to memory. Details: [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md).

## Current verification status

The working Mac available during this build pass is macOS 12.5 with Command Line Tools/Swift 5.7, no Xcode application, no signing identity, and no configured OpenAI key. That environment cannot build an Xcode 16/macOS 14 target or run live hardware/API validation. The repository contains Xcode 16/macOS CI and deterministic tests, but this pass does not claim a successful archive, local hotkey test, microphone test, or live OpenAI test. See [TEST_REPORT.md](TEST_REPORT.md).

## Documentation

- [Build Week scope and Windows reference map](BUILD_WEEK_SCOPE.md)
- [Architecture](ARCHITECTURE.md)
- [OpenAI integration](OPENAI_INTEGRATION.md)
- [Demo script](DEMO_SCRIPT.md)
- [Submission copy](SUBMISSION_COPY.md)
