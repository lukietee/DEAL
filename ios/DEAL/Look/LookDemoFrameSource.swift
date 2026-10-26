import CoreVideo
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Look mode without a camera (Simulator, demo video, UI tests): a drawn record shelf with a
/// Starboy-style vinyl, played as a 10 fps "head" feed. The view starts off to the side, pans onto
/// the record (motion resets the dwell), then holds with a little sway so the dwell completes.
/// `lookAway()` / `lookBack()` pan off and on again to show the fade-out and the memory.
///
/// Enabled with the `-DEALLookDemo` launch argument, or by Demo shortcuts when no camera exists.
@MainActor
final class LookDemoFrameSource: LookFrameSource {
    static let launchArgument = "-DEALLookDemo"

    let name = "Demo feed"
    private(set) var isRunning = false
    var onFrame: ((LookFrame) -> Void)?
    /// Whether the feed is currently pointed away from the record.
    private(set) var lookingAway = false

    private let frameSize = CGSize(width: 720, height: 1280)
    private var scene: CGImage?
    private var timer: Timer?
    private var startedAt: TimeInterval = 0
    /// Pan: from `panFrom` to `panTo` (scene x offsets) starting at `panStart`.
    private var panFrom: CGFloat = 0
    private var panTo: CGFloat = 0
    private var panStart: TimeInterval = 0
    private static let panDuration: TimeInterval = 1.1
    /// Scene offsets: the record is centered at `onRecord`; `offRecord` shows the empty wall.
    private let onRecord: CGFloat = 550
    private let offRecord: CGFloat = 0

    func start() async throws {
        guard !isRunning else { return }
        if scene == nil { scene = Self.drawScene() }
        isRunning = true
        startedAt = ProcessInfo.processInfo.systemUptime
        lookingAway = false
        // Glance at the wall for a moment, then turn to the record.
        panFrom = offRecord
        panTo = onRecord
        panStart = startedAt + 0.8
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    func lookAway() { pan(to: offRecord, away: true) }
    func lookBack() { pan(to: onRecord, away: false) }

    private func pan(to target: CGFloat, away: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        panFrom = currentOffset(now)
        panTo = target
        panStart = now
        lookingAway = away
    }

    private func currentOffset(_ now: TimeInterval) -> CGFloat {
        let t = min(1, max(0, (now - panStart) / Self.panDuration))
        let eased = t * t * (3 - 2 * t)
        return panFrom + (panTo - panFrom) * eased
    }

    private func tick() {
        guard isRunning, let scene, let onFrame else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // A slow, small sway: a real head is never perfectly still.
        let sway = CGFloat(sin((now - startedAt) * 1.3)) * 2.5
        let bob = CGFloat(cos((now - startedAt) * 0.9)) * 1.5
        guard let buffer = render(scene, x: currentOffset(now) + sway, y: 140 + bob) else { return }
        onFrame(LookFrame(pixelBuffer: buffer, timestamp: now))
    }

    /// One frame: the `frameSize` window of the scene at (x, y), top-left origin.
    private func render(_ scene: CGImage, x: CGFloat, y: CGFloat) -> CVPixelBuffer? {
        #if canImport(UIKit)
        let rect = CGRect(x: x.rounded(), y: y.rounded(), width: frameSize.width, height: frameSize.height)
        guard let window = scene.cropping(to: rect) else { return nil }
        return PixelBuffers.make(from: UIImage(cgImage: window))
        #else
        return nil
        #endif
    }

    // MARK: Scene

    /// 1600×1700: warm wall and a wooden shelf on the left (nothing worth pricing), the record
    /// leaning on the shelf further right.
    private static func drawScene() -> CGImage? {
        #if canImport(UIKit)
        let size = CGSize(width: 1600, height: 1700)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { r in
            let ctx = r.cgContext
            // Wall: soft vertical gradient.
            let wall = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [UIColor(red: 0.80, green: 0.76, blue: 0.70, alpha: 1).cgColor,
                                           UIColor(red: 0.66, green: 0.61, blue: 0.55, alpha: 1).cgColor] as CFArray,
                                  locations: [0, 1])!
            ctx.drawLinearGradient(wall, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            // Shelf top and front edge.
            UIColor(red: 0.45, green: 0.31, blue: 0.20, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 1000, width: size.width, height: 34))
            UIColor(red: 0.34, green: 0.23, blue: 0.15, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 1034, width: size.width, height: 666))

            // The record: a black disc peeking out of the sleeve.
            let sleeve = CGRect(x: 640, y: 560, width: 440, height: 440)
            UIColor(white: 0.05, alpha: 1).setFill()
            ctx.fillEllipse(in: CGRect(x: sleeve.maxX - 300, y: sleeve.minY + 20, width: 400, height: 400))
            UIColor(white: 0.16, alpha: 1).setStroke()
            for i in 0..<14 {
                let inset = CGFloat(12 + i * 11)
                ctx.setLineWidth(1)
                ctx.strokeEllipse(in: CGRect(x: sleeve.maxX - 300, y: sleeve.minY + 20, width: 400, height: 400).insetBy(dx: inset, dy: inset))
            }
            UIColor(red: 0.85, green: 0.12, blue: 0.16, alpha: 1).setFill()
            ctx.fillEllipse(in: CGRect(x: sleeve.maxX - 300 + 150, y: sleeve.minY + 170, width: 100, height: 100))

            // Sleeve: deep blue with a dark figure and red title lettering.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 24, color: UIColor.black.withAlphaComponent(0.45).cgColor)
            UIColor(red: 0.05, green: 0.20, blue: 0.42, alpha: 1).setFill()
            ctx.fill(sleeve)
            ctx.restoreGState()
            let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [UIColor(red: 0.20, green: 0.45, blue: 0.80, alpha: 1).cgColor,
                                           UIColor(red: 0.05, green: 0.20, blue: 0.42, alpha: 0).cgColor] as CFArray,
                                  locations: [0, 1])!
            ctx.saveGState()
            ctx.clip(to: sleeve)
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: sleeve.midX, y: sleeve.midY), startRadius: 0,
                                   endCenter: CGPoint(x: sleeve.midX, y: sleeve.midY), endRadius: 260, options: [])
            // Figure: head and shoulders in a dark jacket, a small gold cross.
            UIColor(white: 0.06, alpha: 1).setFill()
            ctx.fillEllipse(in: CGRect(x: sleeve.midX - 62, y: sleeve.minY + 120, width: 124, height: 150))
            let shoulders = UIBezierPath()
            shoulders.move(to: CGPoint(x: sleeve.minX + 40, y: sleeve.maxY))
            shoulders.addCurve(to: CGPoint(x: sleeve.maxX - 40, y: sleeve.maxY),
                               controlPoint1: CGPoint(x: sleeve.minX + 70, y: sleeve.minY + 250),
                               controlPoint2: CGPoint(x: sleeve.maxX - 70, y: sleeve.minY + 250))
            shoulders.close()
            shoulders.fill()
            UIColor(red: 0.93, green: 0.74, blue: 0.30, alpha: 1).setFill()
            ctx.fill(CGRect(x: sleeve.midX - 4, y: sleeve.minY + 320, width: 8, height: 36))
            ctx.fill(CGRect(x: sleeve.midX - 13, y: sleeve.minY + 330, width: 26, height: 7))
            ctx.restoreGState()
            let title = NSAttributedString(string: "STARBOY", attributes: [
                .font: UIFont.systemFont(ofSize: 74, weight: .black),
                .foregroundColor: UIColor(red: 0.90, green: 0.12, blue: 0.18, alpha: 1),
                .kern: 2,
            ])
            title.draw(at: CGPoint(x: sleeve.minX + 26, y: sleeve.minY + 22))
            let artist = NSAttributedString(string: "THE WEEKND", attributes: [
                .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
                .kern: 4,
            ])
            artist.draw(at: CGPoint(x: sleeve.minX + 30, y: sleeve.minY + 104))

            // A plain mug on the left of the shelf: a small, low-contrast object the dwell ignores
            // while the view passes over it.
            UIColor(red: 0.86, green: 0.84, blue: 0.80, alpha: 1).setFill()
            ctx.fill(CGRect(x: 170, y: 920, width: 70, height: 80))
        }
        return image.cgImage
        #else
        return nil
        #endif
    }
}
