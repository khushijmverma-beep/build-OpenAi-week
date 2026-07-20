import AppKit
import Combine
import KeyboardWtfCore
import SwiftUI

@MainActor final class OverlayPanelController: NSObject {
    private let panel: OverlayPanel
    private let store: ObservableAssistantStateStore
    private var observation: AnyCancellable?

    init(store: ObservableAssistantStateStore, coordinator: AssistantCoordinator) {
        self.store = store
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 124), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.contentView = NSHostingView(rootView: AssistantOverlayView(store: store, confirm: { Task { await coordinator.confirmPendingAction() } }))
        observation = store.$snapshot.receive(on: RunLoop.main).sink { [weak self] snapshot in self?.update(snapshot) }
    }

    private func update(_ snapshot: AssistantSnapshot) {
        if snapshot.phase == .idle { panel.orderOut(nil); return }
        panel.ignoresMouseEvents = snapshot.phase != .confirmationRequired
        position()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func position() {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - 20))
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct AssistantOverlayView: View {
    @ObservedObject var store: ObservableAssistantStateStore
    let confirm: () -> Void

    var body: some View {
        let snapshot = store.snapshot
        HStack(spacing: 16) {
            StatusOrb(tone: snapshot.tone, level: snapshot.microphoneLevel, active: snapshot.phase == .listening)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(snapshot.title).font(.system(size: 19, weight: .semibold)).foregroundStyle(.primary)
                    if snapshot.phase == .confirmationRequired { Button("Confirm", action: confirm).buttonStyle(.borderedProminent).controlSize(.small) }
                }
                Text(snapshot.partialTranscript.isEmpty ? snapshot.detail : snapshot.partialTranscript)
                    .font(.system(size: 14, weight: .regular)).foregroundStyle(.secondary).lineLimit(2)
                if let hint = snapshot.cancelHint { Text(hint).font(.caption).foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 0)
            if !snapshot.phase.isTerminal && snapshot.phase != .idle { ElapsedTime(since: snapshot.startedAt).foregroundStyle(.tertiary).font(.caption.monospacedDigit()) }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(width: 560, alignment: .leading)
        .background(VisualEffect(material: .hudWindow, blendingMode: .behindWindow).clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.title). \(snapshot.detail)")
    }
}

private struct StatusOrb: View {
    let tone: OverlayTone; let level: Float; let active: Bool
    private var color: Color { switch tone { case .purple: return .purple; case .red: return .red; case .blue: return .blue; case .amber: return .orange; case .teal: return .teal; case .green: return .green } }
    var body: some View {
        ZStack {
            // Keep the core sharply defined; the blurred layer is only a subtle glow.
            Circle()
                .fill(color.opacity(active ? 0.48 : 0.30))
                .frame(width: active ? 62 : 56, height: active ? 62 : 56)
                .blur(radius: active ? 11 : 8)
            Circle()
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.98), color.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 48, height: 48)
                .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1))
                .shadow(color: color.opacity(0.55), radius: 7, y: 2)
            if active {
                Circle().fill(.white.opacity(0.96)).frame(width: 12, height: 12)
            }
        }
        .frame(width: 62, height: 62)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

private struct ElapsedTime: View {
    let since: Date
    var body: some View { TimelineView(.periodic(from: .now, by: 1)) { context in Text("\(Int(context.date.timeIntervalSince(since)))s") } }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material; let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView { let view = NSVisualEffectView(); view.material = material; view.blendingMode = blendingMode; view.state = .active; return view }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}
