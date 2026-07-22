# ORISIS for macOS

ORISIS (also called Jarvis inside the app) is a native Apple-silicon menu-bar assistant for controlling a personal Mac with voice, keyboard shortcuts, and explicit user-approved actions. It brings together local dictation, concise AI writing help, and a low-latency conversational mode that can work with selected text, visible screen context, applications, browser tasks, files, memories, and saved workflows.

The project started from the Windows keyboard.wtf concept and was rebuilt for macOS rather than copied. The Mac version uses SwiftUI and AppKit, native audio and speech frameworks, Accessibility and ScreenCaptureKit, Keychain, SQLite, and typed automation receipts. ORISIS is designed to act quickly while keeping consequential operations—such as sending an email, deleting content, or changing system state—confirmation-gated.

## Requirements

- macOS 14 or later
- Apple silicon Mac (the published build targets arm64)
- An OpenAI API key supplied by the user
- Internet access for OpenAI Realtime and Responses requests

The app is not notarized yet. macOS may show an **Open Anyway** warning the first time it is opened. A stable Apple Development signing identity is also not installed for this local release, so a Keychain migration or privacy approval may be shown once after installation.

## Download and install

### Website

1. Visit [jarvis.vercel.app](https://jarvis.vercel.app).
2. Click **Download for macOS**.
3. Open the downloaded ZIP and move `keyboard.wtf.app` to `~/Applications` or `/Applications`.
4. Open the app. If macOS warns that it cannot verify the developer, choose **Open**, or use **System Settings → Privacy & Security → Open Anyway**.
5. Open Settings, add your OpenAI API key, and choose **Save** and **Test Connection**.
6. Approve the requested permissions, then use the ORISIS hotkey.

### GitHub Releases

The same build is available from the [GitHub Releases page](https://github.com/khushijmverma-beep/build-OpenAi-week/releases). Download the `ORISIS-macOS-v0.1.6.zip` asset, extract it, and follow the steps above.

For local development, use:

```bash
cd /Users/khushiverma/.codex/worktrees/d4dc/OpenAI
./Scripts/install-app.sh
```

This builds, ad-hoc signs, installs, and launches `~/Applications/keyboard.wtf.app`.

## Shortcuts

| Action | Shortcut |
| --- | --- |
| Dictation | Control + Option + D |
| Smart Writing | Control + Option + K |
| ORISIS / Jarvis | Control + Option + Q |
| Cancel | Control + Option + X |
| Settings | Control + Option + J |
| Stop speaking and keep listening | Control + Option + Command + X |

The hotkeys are stored in the app settings and registered again when the app relaunches. Launch at login can be enabled in Settings where macOS permits it.

## What ORISIS does

- Dictates locally and inserts literal text into the focused app.
- Turns rough speech into concise, ready-to-send writing.
- Holds a natural Realtime voice conversation without requiring a push-to-talk loop.
- Reads selected text and can explain, summarize, translate, or rewrite it into the clipboard.
- Captures and analyzes the screen only after an explicit request.
- Opens and focuses apps, works with windows and files, searches browsers, controls media, and performs safe typed Mac actions.
- Drafts Gmail in a fixed order—recipient, subject, body—leaves the draft open, and asks for confirmation before sending.
- Stores explicit memories and workflows locally so they survive a restart.

## Permissions

Grant permissions to the installed app itself, not the Xcode or debug copy:

- **Microphone:** System Settings → Privacy & Security → Microphone.
- **Accessibility:** Privacy & Security → Accessibility. Required for typing, selected text, hotkeys, and screen clicks.
- **Screen Recording:** Privacy & Security → Screen Recording. Required only for explicit screenshots and screen understanding.
- **Camera:** requested only when a photo is explicitly requested.
- **Automation / Files and Folders / Notifications:** requested only for the related action when macOS requires it.

If a permission appears denied after approval, quit the app, enable the entry for `~/Applications/keyboard.wtf.app`, and reopen that same installed copy. The API key is stored in Keychain and cached locally after its one-time migration so normal launches do not repeatedly ask for the login Keychain password.

## Architecture

`AssistantCoordinator` owns mode state, cancellation, interruption, recovery, confirmation, and tool receipts. `AVAudioCapture` and `AVAudioPlayback` handle microphone and speaker streams. `OnDeviceSpeechRecognizer` powers local Dictation and Smart Writing capture. `OpenAIRealtimeWebSocketClient` handles live Jarvis audio; `OpenAIResponsesService` handles routine text generation and image/screen analysis. `MacActionExecutor` exposes typed, bounded tools backed by AppKit, Accessibility, ScreenCaptureKit, Apple Events, and filesystem-safe services. `SQLiteStore` persists receipts, memories, and workflows; `KeychainCredentialProvider` owns the user credential path.

## OpenAI and Codex

- **OpenAI Realtime** powers the low-latency live voice conversation.
- **OpenAI Responses API** powers Smart Writing, ordinary Responses requests, and explicit screen analysis.
- **GPT-5.6-terra** is retained as a configurable reasoning/escalation model; routine writing uses the configured Responses model.
- **Codex** was used to inspect the repository, implement the native Mac product, diagnose failures, run the build/test loop, package the app, and verify the release/download workflow.

## Known limitations

- The public build is Apple-silicon-only and requires macOS 14 or later.
- It is ad-hoc signed and not notarized; macOS approval steps are expected.
- Accessibility and Screen Recording cannot be granted programmatically and must be approved by the user.
- Screen clicks depend on the current visible UI and can be affected by browser or website layout changes.
- OpenAI features require the user’s own API key, network access, and available account quota.
- Sending, deleting, purchasing, publishing, and other consequential actions remain confirmation-gated.

## Support

- Khushi: [Khushi.jm.verma@gmail.com](mailto:Khushi.jm.verma@gmail.com)
- Tanush: [tanushshah2006@gmail.com](mailto:tanushshah2006@gmail.com)

## Project documents

- [Architecture](ARCHITECTURE.md)
- [OpenAI integration](OPENAI_INTEGRATION.md)
- [Privacy](PRIVACY.md)
- [Security](SECURITY.md)
- [Demo script](DEMO_SCRIPT.md)
- [Build Week scope](BUILD_WEEK_SCOPE.md)
