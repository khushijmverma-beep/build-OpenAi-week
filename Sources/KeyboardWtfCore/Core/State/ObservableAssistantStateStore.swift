import Combine
import Foundation

@MainActor
public final class ObservableAssistantStateStore: ObservableObject, AssistantStateStore {
    @Published public private(set) var snapshot: AssistantSnapshot
    private var terminalDismissTask: Task<Void, Never>?

    public init(initial: AssistantSnapshot = AssistantSnapshot()) { snapshot = initial }

    public func transition(to snapshot: AssistantSnapshot) {
        terminalDismissTask?.cancel()
        self.snapshot = snapshot
        if snapshot.phase.isTerminal {
            terminalDismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_100_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self?.snapshot.phase.isTerminal == true else { return }
                    self?.snapshot = AssistantSnapshot()
                }
            }
        }
    }

    public func updatePartialTranscript(_ text: String) {
        transition(to: AssistantSnapshot(
            phase: snapshot.phase, mode: snapshot.mode, title: snapshot.title, detail: snapshot.detail,
            partialTranscript: text, microphoneLevel: snapshot.microphoneLevel, startedAt: snapshot.startedAt,
            cancelHint: snapshot.cancelHint
        ))
    }

    public func updateMicrophoneLevel(_ level: Float) {
        snapshot = AssistantSnapshot(
            phase: snapshot.phase, mode: snapshot.mode, title: snapshot.title, detail: snapshot.detail,
            partialTranscript: snapshot.partialTranscript, microphoneLevel: max(0, min(level, 1)),
            startedAt: snapshot.startedAt, cancelHint: snapshot.cancelHint
        )
    }
}
