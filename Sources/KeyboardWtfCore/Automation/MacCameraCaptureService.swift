@preconcurrency import AVFoundation
import Foundation

/// Captures one still image after an explicit user request. The session is
/// short-lived and never runs continuously in the background.
public final class MacCameraCaptureService: NSObject, CameraCaptureService, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.yourname.keyboardwtf.camera")
    private var session: AVCaptureSession?
    private var output: AVCapturePhotoOutput?
    private var pendingURL: URL?
    private var pendingContinuation: CheckedContinuation<URL, Error>?

    public override init() { super.init() }

    public func capturePhoto() async throws -> URL {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw AppError.permission(.camera) }
        } else if status != .authorized {
            throw AppError.permission(.camera)
        }

        _ = try setupIfNeeded()
        let directory = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("keyboard.wtf", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("Photo-\(stamp).jpg")

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.pendingURL = url
                self.pendingContinuation = continuation
                self.session?.startRunning()
                self.output?.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
            }
        }
    }

    private func setupIfNeeded() throws -> (AVCaptureSession, AVCapturePhotoOutput) {
        if let session, let output { return (session, output) }
        guard let device = AVCaptureDevice.default(for: .video) else { throw AppError.unsupported("No camera is available on this Mac.") }
        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw AppError.unsupported("The camera input could not be configured.") }
        session.addInput(input)
        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else { throw AppError.unsupported("The camera output could not be configured.") }
        session.addOutput(output)
        session.commitConfiguration()
        self.session = session
        self.output = output
        return (session, output)
    }

    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        queue.async {
            if let error { self.finish(.failure(error)); return }
            guard let data = photo.fileDataRepresentation(), let url = self.pendingURL else {
                self.finish(.failure(AppError.unsupported("The camera did not return an image.")))
                return
            }
            do { try data.write(to: url, options: .atomic); self.finish(.success(url)) }
            catch { self.finish(.failure(error)) }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        session?.stopRunning()
        pendingURL = nil
        let continuation = pendingContinuation
        pendingContinuation = nil
        continuation?.resume(with: result)
    }
}
