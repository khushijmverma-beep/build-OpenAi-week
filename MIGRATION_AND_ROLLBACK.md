# Migration and rollback

The core protocols isolate change: `LocalSpeechRecognizer` can move from the current on-device recognizer to WhisperKit; `OpenAIRealtimeClient` can switch from direct BYOK WebSocket credentials to an ephemeral token broker or WebRTC; `BrowserAutomationEngine` remains a boundary; and SQLite is behind memory/workflow/receipt protocols. Disable a problematic integration by changing the injected implementation in `AppEnvironment`, while retaining the coordinator, overlay, permissions, and typed receipts.
