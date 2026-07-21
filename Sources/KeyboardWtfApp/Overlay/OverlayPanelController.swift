import AppKit
import Combine
import KeyboardWtfCore
import SwiftUI

@MainActor final class OverlayPanelController: NSObject {
    private let panel: OverlayPanel
    private let store: ObservableAssistantStateStore
    private var observation: AnyCancellable?
    private var screenObservation: NSObjectProtocol?
    private var spaceObservation: NSObjectProtocol?

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
        panel.contentView = NSHostingView(rootView: AssistantOverlayView(
            store: store,
            confirm: { Task { await coordinator.confirmPendingAction() } },
            setListeningPaused: { paused in await coordinator.setListeningPaused(paused) },
            stopSpeakingAndListen: { await coordinator.stopSpeakingAndListen() }
        ))
        observation = store.$snapshot.receive(on: RunLoop.main).sink { [weak self] snapshot in self?.update(snapshot) }
        screenObservation = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.repositionIfVisible() }
        }
        spaceObservation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.repositionIfVisible() }
        }
    }

    deinit {
        if let screenObservation { NotificationCenter.default.removeObserver(screenObservation) }
        if let spaceObservation { NSWorkspace.shared.notificationCenter.removeObserver(spaceObservation) }
    }

    private func update(_ snapshot: AssistantSnapshot) {
        if snapshot.phase == .idle { panel.orderOut(nil); return }
        let jarvisCanPause = snapshot.mode == .jarvis && !snapshot.phase.isTerminal && snapshot.phase != .idle
        panel.ignoresMouseEvents = snapshot.phase != .confirmationRequired && !jarvisCanPause
        position()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func repositionIfVisible() {
        guard panel.isVisible else { return }
        position()
        panel.orderFrontRegardless()
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
    let setListeningPaused: (Bool) async -> Bool
    let stopSpeakingAndListen: () async -> Bool
    @State private var listeningPaused = false
    @State private var pauseRequestInFlight = false

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
            if snapshot.mode == .jarvis && snapshot.phase == .speaking {
                Button {
                    guard !pauseRequestInFlight else { return }
                    pauseRequestInFlight = true
                    Task { @MainActor in
                        _ = await stopSpeakingAndListen()
                        pauseRequestInFlight = false
                    }
                } label: {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(pauseRequestInFlight)
                .help("Stop speaking and listen")
                .accessibilityLabel("Stop speaking and listen")
            } else if snapshot.mode == .jarvis && !snapshot.phase.isTerminal && snapshot.phase != .idle {
                Button {
                    let requestedPause = !listeningPaused
                    guard !pauseRequestInFlight else { return }
                    pauseRequestInFlight = true
                    Task { @MainActor in
                        if await setListeningPaused(requestedPause) { listeningPaused = requestedPause }
                        pauseRequestInFlight = false
                    }
                } label: {
                    Image(systemName: listeningPaused ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(pauseRequestInFlight)
                .help(listeningPaused ? "Resume listening" : "Pause listening")
                .accessibilityLabel(listeningPaused ? "Resume listening" : "Pause listening")
            }
            if !snapshot.phase.isTerminal && snapshot.phase != .idle { ElapsedTime(since: snapshot.startedAt).foregroundStyle(.tertiary).font(.caption.monospacedDigit()) }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(width: 560, alignment: .leading)
        .background(VisualEffect(material: .hudWindow, blendingMode: .behindWindow).clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.title). \(snapshot.detail)")
        .onChange(of: snapshot.phase) { _, phase in
            if phase == .connecting || phase == .idle || phase.isTerminal { listeningPaused = false }
        }
    }
}

private struct StatusOrb: View {
    let tone: OverlayTone; let level: Float; let active: Bool
    private var accent: Color { switch tone { case .purple: return .indigo; case .red: return .red; case .blue: return .blue; case .amber: return .orange; case .teal: return .teal; case .green: return .green } }
    var body: some View {
        ZStack {
            // Keep the orb legible at a glance. Phase color is only a faint tint;
            // the glass surface and white edge carry most of the visual weight.
            Circle()
                .fill(accent.opacity(active ? 0.13 : 0.07))
                .frame(width: 48, height: 48)
                .blur(radius: 3)
            Circle()
                .fill(.thinMaterial)
                .overlay(Circle().fill(accent.opacity(active ? 0.18 : 0.10)))
                .frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(.white.opacity(0.42), lineWidth: 1))
                .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
            if active {
                Circle()
                    .fill(.white.opacity(0.92))
                    .frame(width: 8, height: 8)
                    .scaleEffect(0.9 + CGFloat(min(level, 1)) * 0.35)
            }
        }
        .frame(width: 54, height: 54)
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
