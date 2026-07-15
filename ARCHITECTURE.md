# Architecture

`keyboard.wtf` uses a Swift Package core and a small SwiftUI/AppKit app shell. Mutable feature state is owned by actors or injected objects; there is no service locator or global mutable app state.

```mermaid
flowchart LR
  H[Global hotkey or menu] --> C[AssistantCoordinator]
  C --> S[Observable state store]
  S --> O[Non-activating NSPanel overlay]
  C --> L[Local on-device speech]
  C --> R[OpenAI Responses]
  C --> RT[OpenAI Realtime WebSocket]
  RT --> T[Typed tool executor]
  T --> P[Permission policy]
  T --> A[Action receipts]
  A --> DB[(SQLite)]
```

## Mode flow

```mermaid
stateDiagram-v2
  [*] --> idle
  idle --> listening: Dictation / Smart Writing / Jarvis
  listening --> transcribing: finite capture ends
  transcribing --> thinking: Smart Writing
  thinking --> executing: insert or tool
  executing --> done
  listening --> speaking: Realtime output
  speaking --> listening: barge-in
  confirmationRequired --> executing: exact confirm
  state "confirmationRequired" as confirmationRequired
  listening --> cancelled: cancel
  transcribing --> cancelled: cancel
  thinking --> cancelled: cancel
  executing --> cancelled: cancel
  done --> idle
  cancelled --> idle
```

## Realtime and tools

```mermaid
sequenceDiagram
  participant Mic
  participant App as Swift app
  participant RT as OpenAI Realtime
  participant Tool as typed executor
  Mic->>App: PCM16 microphone chunk
  App->>RT: input_audio_buffer.append
  RT-->>App: transcript/audio/tool events
  App->>Tool: closed ToolName + decoded arguments
  Tool-->>App: ActionReceipt
  App->>RT: function_call_output receipt JSON
  RT-->>App: spoken follow-up
```

The WebSocket client owns bounded, explicit receive/send work; the coordinator owns cancellation and never considers a model statement evidence of success. The Mac overlay receives published snapshots and is a non-key panel, so it does not steal the focused app.

## Persistence and cancellation

SQLite stores migrations, explicit personal memories, aliases, workflows, workflow runs, receipts, action/failure history, conversation summaries, and permission events. The current access layer writes memories/workflows/receipts and creates the remaining tables for forward migration. Sensitive values are rejected from automatic memory storage.

Cancellation rotates an operation identifier, stops AVAudioEngine and AVAudioPlayerNode, cancels local recognition tasks, sends Realtime cancellation/truncation, clears pending confirmation, and checks the operation identifier before a late transcription or Responses result can insert text.
