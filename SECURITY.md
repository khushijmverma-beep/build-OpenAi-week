# Security

## Controls

- BYOK secrets are stored with `kSecClassGenericPassword` in Keychain; Settings masks status and supports deletion.
- `OPENAI_API_KEY` is a development/CI override only. `.env` is ignored and `.env.example` is empty.
- `Scripts/scan-secrets.sh` rejects likely keys, bearer tokens, and non-empty key assignments; CI runs it before builds.
- `RedactingLogger` removes API-key/bearer-token patterns from structured local logs.
- Tools are a closed `ToolName` enum. The model cannot emit arbitrary shell, AppleScript, process, mouse-coordinate, or browser instructions.
- Each executor result is an `ActionReceipt`; Jarvis sends that evidence back before discussing completion.
- Restart and shutdown enter a time-bounded confirmation state and require exact “confirm” or an explicit overlay click. Generic “yes” is not a confirmation path.
- Clipboard fallbacks snapshot and restore the previous pasteboard.

## Threat model and limits

The app does not bypass macOS TCC permissions. Accessibility, microphone, screen recording, camera, and Automation permission failures become visible app states. A local BYOK desktop application necessarily has a user-held key; production distribution should replace direct keys with short-lived server credentials. The current system-control executor refuses to claim a verified restart/shutdown/power action until the local permission and verification path is tested.
