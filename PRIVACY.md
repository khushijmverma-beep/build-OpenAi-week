# Privacy

## Local by default

- Keychain stores the API key.
- Dictation uses a local-only on-device speech recognizer and disallows its remote recognition fallback.
- SQLite holds explicit non-sensitive memories, workflows, and action receipts.
- Clipboard content is restored after a temporary selection/insertion fallback.
- Audio is not retained after recognition. No hidden cloud sync is implemented.

## Sent to OpenAI only on an active request

- Smart Writing sends its captured transcript and compact instruction.
- Jarvis streams microphone audio only during an active Realtime conversation and returns tool receipts to that same session.
- A future screen/camera feature must send only an explicitly captured, in-memory image and dispose it after use.

The app does not automatically store API keys, passwords, full clipboard contents, screen images, camera images, or full conversations. Selected text is not saved as memory without an explicit “remember” action.
