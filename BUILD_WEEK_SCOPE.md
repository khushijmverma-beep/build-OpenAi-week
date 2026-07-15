# OpenAI Build Week 2026 scope

Track: Apps for Your Life. Product: `keyboard.wtf` for macOS. Default assistant name: Jarvis. Bundle identifier: `com.yourname.keyboardwtf` until the owner supplies a production identifier/team.

## Windows reference map

The product reference was analyzed at commit `946a156e132a04ef4353152fd1ed2f744c3c1b91`. This pass inspected the tracked solution, project configuration, all source and test files (about 14,122 C# lines), installer/scripts, web settings surface, resources, and documentation—not merely the README.

The Windows implementation is a .NET 8 Windows Forms tray app. `KeyboardWtfApp` composes Win32 hotkeys, NAudio recording, Vosk streaming/Whisper final recognition, destination routing, a browser-hosted settings server, and a `VoiceOverlayForm`. It has multiple recording modes: literal dictation, smart/destination writing, commands, and a Gemini live conversation. `VoiceCaptureService` owns recording/transcription/post-processing; `CommandRegistry` connects hotkeys to it. Jarvis uses one very large `GeminiLiveConversationService` plus a 1,977-line `JarvisAutomationService`. App resolution, fuzzy matching, learned aliases, bounded file search, browser launching, permission policy, routines/memory, receipts/history, camera and screen guidance live in separate services but share a global mutable `KeyboardWtfState`.

### Behaviours retained

- One shortcut starts each voice mode; the same shortcut finishes a finite capture.
- Fast partial transcript, silence/pause behaviour, literal dictation, filler cleanup, and clipboard-preserving fallback are familiar.
- App aliases, fuzzy resolution, bounded user-folder search, safe URL opening, explicit action receipts, and routine/workflow ideas are retained.
- The overlay remains a compact, top-centre status surface with listening, thinking, executing, speaking, done, cancellation, and error states.

### Windows decisions deliberately replaced

| Windows reference | Native macOS replacement |
| --- | --- |
| WinForms tray and overlay | `NSStatusItem`, non-activating `NSPanel`, SwiftUI overlay |
| Static global runtime state | injected services and an observable state store |
| Browser-hosted localhost settings | native SwiftUI Settings scene |
| Provider registry with Claude/Gemini/DeepSeek/Perplexity | OpenAI-only model catalogue |
| Large dynamic automation service | closed `ToolName` enum, typed arguments, receipt evidence |
| JSON file memory | migrated local SQLite tables with FTS-ready schema |
| Win32 SendInput/clipboard calls | Accessibility first, temporary native paste fallback |
| Windows app discovery/registry scan | `NSWorkspace`, running apps, Applications directories |

### Reference strengths and risks

The reference proves valuable product detail: safe fallback paths, practical app ranking, hotkey conflict tests, a useful permission policy, short memory retention, and explicit action history. Its main maintainability risks are global mutable state, no isolation between live conversation/audio/automation, provider-specific behaviour spread through the app, browser-based settings, giant orchestration classes, stringly-typed tool arguments, and platform-private/fragile implementations. This Mac code treats those as design constraints, not source to port.

## Scope status

The repository implements the native menu-bar/overlay foundation, explicit state machine, defaults hotkey registration, Keychain BYOK, local-only speech adapter, Responses and Realtime transports, typed receipts, local SQLite, selected-text/clipboard pipeline, app/file/window foundations, memory, workflow persistence, and native Settings.

Screen recording, screen insight, camera capture, Spaces control, Spotify, launch-at-login, detailed local-model downloads, and full browser automation are intentionally outside the reliable initial runtime path. This matches the P1/P2 boundary rather than claiming shallow support.
