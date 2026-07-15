# Codex collaboration

Codex analyzed the complete tracked Windows reference at a pinned commit, identified product behaviours worth retaining, and explicitly rejected its global-state, provider-sprawl, web-settings, and monolithic-automation patterns for the Mac implementation. It proposed the protocol/actor boundary, state machine, Keychain/SQLite design, OpenAI routing, typed receipts, cancellation checks, and the verification plan.

The product owner supplied the assistant identity, behaviour reference, safety requirements, track, OpenAI-only constraint, and build priorities. The outstanding Xcode/hardware validation must be performed by the Mac operator; this document and `TEST_REPORT.md` distinguish source-level implementation from observed runtime evidence.
