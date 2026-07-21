import AVFoundation
import Foundation

public final class AVAudioCapture: NSObject, AudioCaptureService {
    public var onAudioChunk: ((Data, Float) -> Void)?
    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var isRunning = false

    public override init() { super.init() }

    public func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { throw AppError.audio("Unable to prepare microphone conversion.") }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 1_024, format: sourceFormat) { [weak self] buffer, _ in self?.convert(buffer) }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
    }

    private func convert(_ input: AVAudioPCMBuffer) {
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4_096) else { return }
        var error: NSError?
        var supplied = false
        let result = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard result != .error, error == nil, output.frameLength > 0, let pointer = output.int16ChannelData?.pointee else { return }
        let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: pointer, count: byteCount)
        let level = rmsLevel(input)
        onAudioChunk?(data, level)
    }

    private func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?.pointee else { return 0 }
        let frames = Int(buffer.frameLength); guard frames > 0 else { return 0 }
        let sum = (0..<frames).reduce(Float(0)) { $0 + channel[$1] * channel[$1] }
        return min(1, sqrt(sum / Float(frames)) * 4)
    }
}

public final class AVAudioPlayback: AudioPlaybackService {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private let lock = NSLock()
    private let logger: Logger
    private var prepared = false

    public init(logger: Logger = RedactingLogger()) { self.logger = logger }

    public func enqueuePCM16(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard prepareIfNeeded() else {
            logger.error("audio.playback_unavailable", metadata: [:])
            return
        }
        let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        data.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress, let destination = buffer.int16ChannelData?.pointee else { return }
            destination.update(from: source.assumingMemoryBound(to: Int16.self), count: Int(frames))
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
        if !player.isPlaying { logger.error("audio.playback_did_not_start", metadata: [:]) }
    }

    public func stop() { lock.lock(); player.stop(); lock.unlock() }

    private func prepareIfNeeded() -> Bool {
        guard !prepared else { return true }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
            prepared = true
            return true
        } catch {
            prepared = false
            logger.error("audio.playback_start_failed", metadata: ["error": error.localizedDescription])
            return false
        }
    }
}

public actor PauseDetector {
    private var lastSpeech = Date()
    private let threshold: Float
    private let pause: TimeInterval
    public init(threshold: Float = 0.035, pause: TimeInterval = 0.9) { self.threshold = threshold; self.pause = pause }
    public func ingest(level: Float) { if level >= threshold { lastSpeech = Date() } }
    public func detectedPause(now: Date = Date()) -> Bool { now.timeIntervalSince(lastSpeech) >= pause }
}
