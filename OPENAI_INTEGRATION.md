# OpenAI integration

Only the official OpenAI API is used.

## Routing

| Job | Default | Escalation |
| --- | --- | --- |
| Jarvis speech-to-speech | `gpt-realtime-2.1` | none during a live voice turn |
| Smart Writing, selection actions, ordinary vision | `gpt-5.4-mini` | `gpt-5.6-terra` only after an explicit difficult/high-value decision |
| Advanced reasoning | not automatic | `gpt-5.6-terra` configurable in Diagnostics |

The model strings live in `ModelCatalog`. Settings may override them, but a production app must validate availability against the configured key before use.

## Responses

`OpenAIResponsesService` sends a compact `POST /v1/responses` request with model, system instructions, and a typed input message. Smart Writing instructs the model to return only rewritten text, preserve facts/names/URLs/numbers/code, remove filler/false starts, and never add commentary. Non-2xx responses become typed app errors; no response is silently converted to a success.

## Realtime

`OpenAIRealtimeWebSocketClient` uses `URLSessionWebSocketTask` and the current GA event model—no beta header. It configures 24 kHz PCM input/output and semantic VAD via `session.update`, sends chunks with `input_audio_buffer.append`, reads `response.output_audio.delta`, recognizes speech-start barge-in events, and returns typed action receipts with `conversation.item.create`/`function_call_output`. For WebSocket barge-in it stops local playback and emits response cancellation plus conversation truncation.

The authoritative implementation references checked during this build are [Realtime conversations](https://developers.openai.com/api/docs/guides/realtime-conversations), [Realtime overview](https://developers.openai.com/api/docs/guides/realtime), [Function calling](https://developers.openai.com/api/docs/guides/function-calling), and [Responses text generation](https://developers.openai.com/api/docs/guides/text). Those docs identify `gpt-realtime-2.1`, 24 kHz PCM session configuration, `input_audio_buffer.append`, `response.output_audio.delta`, `function_call_output`, and client-managed WebSocket interruption handling.

## Credentials and safety ID

The API key comes from Keychain or `OPENAI_API_KEY` for development/CI. It is not serialized into settings, logged, included in URLs, or returned to the Settings view. A random local installation identifier is SHA-256-hashed before it is attached as a privacy-preserving Realtime safety identifier. It is not derived from user identity, hostname, Apple ID, or files.

The current local environment has no key, so real Responses/Realtime smoke tests were not run. See [TEST_REPORT.md](TEST_REPORT.md).
