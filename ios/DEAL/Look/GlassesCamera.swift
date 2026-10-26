// Look mode frames from the Meta glasses camera (MWDATCamera 1.0.1).
//
// Rides on MetaGlassesDisplay's DeviceSession (never a second one): registers as a session
// client, so on every session `.started` it runs
//   Wearables.checkPermissionStatus(.camera) (→ requestPermission, opens Meta AI once)
//   → session.addCamera(config:) → camera.stream listeners → stream.start()
// and on teardown camera.stop(). Reconnects re-attach automatically.
// Frames arrive on an SDK queue; FrameGate drops everything above ~10 fps (and anything
// that arrives while the main actor is still busy with the previous frame).

import CoreMedia
import CoreVideo
import Foundation
import Observation
import os
import UIKit
import MWDATCamera
import MWDATCore

enum GlassesCameraState: Equatable, Sendable {
    case idle
    case waitingForGlasses
    case starting
    case streaming
    /// Temporarily not streaming (hinges closed, too hot…). Resumes on its own.
    case paused(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Off"
        case .waitingForGlasses: "Waiting for glasses…"
        case .starting: "Starting camera…"
        case .streaming: "Streaming"
        case .paused(let reason): reason
        case .failed(let reason): reason
        }
    }
}

enum LookSourceError: LocalizedError {
    case glassesNotConnected
    case cameraUnavailable
    case cameraDenied

    var errorDescription: String? {
        switch self {
        case .glassesNotConnected: "Meta glasses aren't connected."
        case .cameraUnavailable: "No camera available."
        case .cameraDenied: "Camera access denied. Allow it in Settings."
        }
    }
}

@MainActor
@Observable
final class GlassesCamera: LookFrameSource {
    let name = "Meta glasses camera"

    private(set) var state: GlassesCameraState = .idle
    private(set) var isRunning = false
    private(set) var lastError: String?
    @ObservationIgnored var onFrame: ((LookFrame) -> Void)?

    // 504×896 portrait at 15 fps from the glasses, ≤ 10 fps to Look. Raw frames, so the
    // sample buffer already carries a CVPixelBuffer (no HEVC decode on the phone).
    static let configuration = StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 15)
    private static let clientKey = "look.camera"
    private static let maxRestarts = 3

    private let glasses: MetaGlassesDisplay
    @ObservationIgnored private var camera: Camera?
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var tokens: [any AnyListenerToken] = []
    @ObservationIgnored private var attachTask: Task<Void, Never>?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private let gate = FrameGate(minInterval: 0.1)

    init(glasses: MetaGlassesDisplay) {
        self.glasses = glasses
    }

    /// Throws if the glasses aren't connected (or connecting): use `PhoneCameraSource` then.
    /// Otherwise returns at once; `state` follows the stream (frames start once it's up).
    func start() async throws {
        guard !isRunning else { return }
        guard glasses.wantsConnection else { throw LookSourceError.glassesNotConnected }
        isRunning = true
        lastError = nil
        restarts = 0
        state = .waitingForGlasses
        glasses.addSessionClient(Self.clientKey,
                                 attach: { [weak self] session in self?.attach(to: session) },
                                 detach: { [weak self] in self?.detach() })
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        glasses.removeSessionClient(Self.clientKey)   // calls detach() if attached
        detach()
        state = .idle
    }

    // MARK: - Attach / detach

    private func attach(to session: DeviceSession) {
        detach()
        self.session = session
        state = .starting
        attachTask = Task { [weak self] in
            await self?.runAttach(session)
            self?.attachTask = nil
        }
    }

    private func runAttach(_ session: DeviceSession) async {
        // Glasses camera permission is per app, granted in Meta AI (not the iOS camera prompt).
        let wearables = Wearables.shared
        do {
            if try await wearables.checkPermissionStatus(.camera) != .granted {
                guard !Task.isCancelled, self.session === session else { return }
                guard try await wearables.requestPermission(.camera) == .granted else {
                    state = .failed("Camera access denied in Meta AI")
                    return
                }
            }
        } catch {
            guard self.session === session else { return }
            state = .failed("Camera permission: \(error.description)")
            return
        }
        guard !Task.isCancelled, isRunning, self.session === session else { return }

        let camera: Camera
        do {
            guard let added = try session.addCamera(config: Self.configuration) else {
                state = .failed("These glasses have no camera stream")
                return
            }
            camera = added
        } catch {
            state = .failed("Couldn't add the glasses camera: \(error.description)")
            return
        }
        self.camera = camera

        let stream = camera.stream
        tokens.append(stream.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in self?.handleStreamState(state, from: camera) }
        })
        tokens.append(stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor [weak self] in self?.handleStreamError(error, from: camera) }
        })
        let gate = self.gate
        tokens.append(stream.videoFramePublisher.listen { [weak self] frame in
            guard gate.admit() else { return }
            guard let lookFrame = Self.lookFrame(from: frame) else { gate.done(); return }
            Task { @MainActor [weak self] in
                defer { gate.done() }
                guard let self, self.isRunning, self.camera === camera else { return }
                self.onFrame?(lookFrame)
            }
        })
        stream.start()
    }

    private func detach() {
        attachTask?.cancel()
        attachTask = nil
        restartTask?.cancel()
        restartTask = nil
        tokens = []   // dropping the tokens stops the listeners
        if let camera {
            self.camera = nil
            camera.stop()   // cascades to camera.stream
        }
        session = nil
        if isRunning { state = .waitingForGlasses }
    }

    private func handleStreamState(_ streamState: StreamState, from camera: Camera) {
        guard camera === self.camera, isRunning else { return }
        switch streamState {
        case .streaming:
            restarts = 0
            lastError = nil
            state = .streaming
        case .waitingForDevice:
            state = .waitingForGlasses
        case .starting:
            if case .paused = state { break }   // keep the pause reason while it resumes
            state = .starting
        case .paused:
            if case .paused = state { break }
            state = .paused("Camera paused")
        case .stopped:
            restartAfterUnexpectedStop()
        case .stopping:
            break
        @unknown default:
            break
        }
    }

    /// Stream errors surface as state; none of them tear the glasses session down.
    private func handleStreamError(_ error: StreamError, from camera: Camera) {
        guard camera === self.camera, isRunning else { return }
        lastError = error.description
        switch error {
        case .hingesClosed:
            state = .paused("Glasses folded. Unfold them to resume.")
        case .thermalHot:
            state = .paused("Glasses too hot. Camera paused.")
        case .peakPowerLimit:
            state = .paused("Glasses power limit. Camera paused.")
        case .batteryLow:
            state = .failed("Glasses battery low")
        case .permissionDenied:
            state = .failed("Camera access denied in Meta AI")
        case .deviceNotConnected, .deviceNotFound:
            state = .waitingForGlasses
        default:
            break   // timeout / streaming errors: the stream state decides
        }
    }

    /// The stream stopped while the session is still up: re-add the camera a few times.
    private func restartAfterUnexpectedStop() {
        guard let session, restartTask == nil else { return }
        if case .failed = state { return }
        restarts += 1
        guard restarts <= Self.maxRestarts else {
            state = .failed(lastError ?? "Glasses camera stopped")
            return
        }
        state = .paused("Camera stopped. Restarting…")
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(self?.restarts ?? 1)))
            guard let self, !Task.isCancelled, self.isRunning, self.session === session else { return }
            self.restartTask = nil
            let attempts = self.restarts
            self.attach(to: session)
            self.restarts = attempts
        }
    }

    // MARK: - Frames (SDK queue)

    /// Raw frames carry their CVPixelBuffer (already upright, as Meta's samples display it).
    /// Anything else (e.g. a compressed buffer) goes through the SDK's UIImage conversion.
    private nonisolated static func lookFrame(from frame: VideoFrame) -> LookFrame? {
        let sampleBuffer = frame.sampleBuffer
        let seconds = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let timestamp = seconds.isFinite ? seconds : ProcessInfo.processInfo.systemUptime
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            return LookFrame(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }
        guard let image = frame.makeUIImage(), let pixelBuffer = PixelBuffers.make(from: image) else { return nil }
        return LookFrame(pixelBuffer: pixelBuffer, timestamp: timestamp)
    }
}

// MARK: - Shared frame helpers (glasses + phone sources)

/// Admits at most one frame per `minInterval`, and none while the previous one is still
/// waiting for the main actor. Thread-safe; called from capture queues.
final class FrameGate: Sendable {
    private struct Clock { var last: TimeInterval = 0; var inFlight = false }
    private let minInterval: TimeInterval
    private let clock = OSAllocatedUnfairLock(initialState: Clock())

    init(minInterval: TimeInterval) {
        self.minInterval = minInterval
    }

    func admit() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return clock.withLock { c in
            guard !c.inFlight, now - c.last >= minInterval else { return false }
            c.last = now
            c.inFlight = true
            return true
        }
    }

    func done() {
        clock.withLock { $0.inFlight = false }
    }
}

enum PixelBuffers {
    /// Draws `image` (honoring its orientation, so the result is upright) into a BGRA buffer.
    static func make(from image: UIImage) -> CVPixelBuffer? {
        let size = image.size
        let width = Int(size.width * image.scale), height = Int(size.height * image.scale)
        guard width > 0, height > 0 else { return nil }
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // UIKit draws top-left origin; flip the bitmap context to match.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / size.width, y: -CGFloat(height) / size.height)
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(origin: .zero, size: size))
        UIGraphicsPopContext()
        return buffer
    }
}
