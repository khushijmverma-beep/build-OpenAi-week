import AVFoundation
import Foundation
import Speech

/// Uses only macOS's on-device speech model. It deliberately refuses a remote recognition path.
public final class OnDeviceSpeechRecognizer: NSObject, LocalSpeechRecognizer {
    public let partialTranscript: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let locale: Locale
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var completion: CheckedContinuation<String, Error>?
    private var latest = ""
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!

    public init(locale: Locale = Locale.current) {
        self.locale = locale
        var continuation: AsyncStream<String>.Continuation!
        partialTranscript = AsyncStream { continuation = $0 }
        self.continuation = continuation
        super.init()
    }

    deinit { task?.cancel(); continuation.finish() }

    public func prepare() async throws {
        let status = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        guard status == .authorized else { throw AppError.permission(.microphone) }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else { throw AppError.modelUnavailable("a local macOS speech model for \(locale.identifier)") }
    }

    public func startStreaming() async throws {
        try await prepare()
        task?.cancel(); latest = ""
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = true
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw AppError.modelUnavailable("a local macOS speech model") }
        request = recognitionRequest
        task = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.latest = result.bestTranscription.formattedString
                self.continuation.yield(self.latest)
                if result.isFinal { self.completion?.resume(returning: self.latest); self.completion = nil }
            }
            if let error, self.completion != nil { self.completion?.resume(throwing: error); self.completion = nil }
        }
    }

    public func append(audio: Data) async {
        guard let request, !audio.isEmpty else { return }
        let frames = AVAudioFrameCount(audio.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        audio.withUnsafeBytes { raw in
            guard let source = raw.baseAddress, let destination = buffer.int16ChannelData?.pointee else { return }
            destination.assign(from: source.assumingMemoryBound(to: Int16.self), count: Int(frames))
        }
        request.append(buffer)
    }

    public func finish() async throws -> String {
        guard let request else { return latest }
        request.endAudio()
        return try await withCheckedThrowingContinuation { continuation in
            self.completion = continuation
            if !latest.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in guard let self, self.completion != nil else { return }; self.completion?.resume(returning: self.latest); self.completion = nil } }
        }
    }

    public func cancel() async { task?.cancel(); request?.endAudio(); completion?.resume(throwing: AppError.cancellation); completion = nil; request = nil; task = nil }
}
