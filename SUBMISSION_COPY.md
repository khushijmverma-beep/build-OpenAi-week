# Submission copy

**Project name:** keyboard.wtf for macOS
**Tagline:** Press a shortcut. Speak naturally. Let your Mac keep up.

**Category:** Apps for Your Life

**Inspiration:** Everyday computer work still breaks attention across typing, wording, windows, files, and repetitive clicks. The keyboard can be a fast, memorable trigger without being the main input device.

**What it does:** keyboard.wtf is a native menu-bar companion with local Dictation, OpenAI-powered Smart Writing, and a live Jarvis conversation. It delivers text to the focused app, understands selected text, and uses typed, receipt-backed Mac actions rather than an unrestricted shell.

**How it was built:** Swift 6 architecture, SwiftUI, AppKit `NSPanel`, AVFoundation, Carbon hotkeys, Accessibility APIs, Keychain, SQLite, OpenAI Responses, and the GA Realtime WebSocket flow. Routine writing uses `gpt-5.4-mini`; live speech uses `gpt-realtime-2.1`; `gpt-5.6-terra` is an explicit escalation path.

**Challenges:** preserving focus while displaying an overlay, avoiding late effects after cancellation, building safe computer actions without a generic shell, and maintaining a useful fallback when macOS permission scopes differ by app.

**Accomplishments:** an explicit interaction state machine, non-activating overlay, local-only dictation path, Keychain credentials, clipboard preservation, typed tool receipts, confirmation expiry, and a SQLite foundation for memory/workflows.

**Lessons and next:** validate the full build on macOS 14/Xcode 16, benchmark a WhisperKit adapter against the on-device recognizer, add ScreenCaptureKit only with an honest permission UX, and integrate browser automation only behind the existing boundary.

**Codex and GPT-5.6:** Codex accelerated reference analysis, Swift architecture, test design, documentation, and implementation iterations. GPT-5.6 is not used for routine runtime work; `gpt-5.6-terra` remains an intentionally narrow advanced-reasoning option.
