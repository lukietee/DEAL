// Look mode frames from the iPhone's back camera: the fallback when the glasses aren't
// connected. AVCaptureSession + AVCaptureVideoDataOutput (BGRA, portrait-rotated so buffers
// are upright), throttled to ~10 fps by the shared FrameGate. The Simulator has no camera:
// `start()` throws `LookSourceError.cameraUnavailable` there.

@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Observation

@MainActor
@Observable
final class PhoneCameraSource: LookFrameSource {
    let name = "iPhone camera"

    private(set) var isRunning = false
    @ObservationIgnored var onFrame: ((LookFrame) -> Void)?

    /// For an `AVCaptureVideoPreviewLayer` behind the overlay, if the UI wants a live preview.
    @ObservationIgnored let captureSession = AVCaptureSession()
    @ObservationIgnored private var configured = false
    @ObservationIgnored private let delegate = FrameDelegate()
    @ObservationIgnored private let queue = DispatchQueue(label: "deal.look.phoneCamera", qos: .userInitiated)

    init() {
        let gate = delegate.gate
        delegate.deliver = { [weak self] frame in
            Task { @MainActor [weak self] in
                defer { gate.done() }   // keeps ≤ 1 frame queued for the main actor
                guard let self, self.isRunning else { return }
                self.onFrame?(frame)
            }
        }
    }

    func start() async throws {
        guard !isRunning else { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw LookSourceError.cameraDenied }
        if !configured { try configure() }
        isRunning = true
        // startRunning blocks; keep it off the main thread (as in QRScannerView).
        nonisolated(unsafe) let session = captureSession
        queue.async { if !session.isRunning { session.startRunning() } }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        nonisolated(unsafe) let session = captureSession
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            throw LookSourceError.cameraUnavailable
        }
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        // 720p is plenty for a ≤ 768 px identify crop.
        if captureSession.canSetSessionPreset(.hd1280x720) { captureSession.sessionPreset = .hd1280x720 }
        guard captureSession.canAddInput(input) else { throw LookSourceError.cameraUnavailable }
        captureSession.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: queue)
        guard captureSession.canAddOutput(output) else { throw LookSourceError.cameraUnavailable }
        captureSession.addOutput(output)
        // The app is portrait-only: rotate buffers so they come out upright.
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        // Cap the sensor rate too, so we don't spend power on frames FrameGate drops anyway.
        if (try? device.lockForConfiguration()) != nil {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15)
            device.unlockForConfiguration()
        }
        configured = true
    }

    /// Sample-buffer delegate on the capture queue; hands throttled frames to the main actor.
    private final class FrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        let gate = FrameGate(minInterval: 0.1)
        /// Set once in `PhoneCameraSource.init`, before capture starts.
        var deliver: (@Sendable (LookFrame) -> Void)?

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), gate.admit() else { return }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            guard let deliver else { gate.done(); return }
            deliver(LookFrame(pixelBuffer: pixelBuffer, timestamp: timestamp))
        }
    }
}
