import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Vision

/// The on-device half of Look mode: Apple Vision saliency for candidate boxes, a Vision object
/// tracker for the highlighted item, a cheap motion score, and the JPEG crop + perceptual hash sent
/// to `/look/identify`. Everything runs on one serial queue (Vision's sequence handler and tracker
/// are stateful), so `LookScanner` stays on the main actor and only ever awaits results.
///
/// Boxes in and out are normalized with the origin top-left (like `LookHighlight.box`); Vision's
/// bottom-left boxes are flipped here and nowhere else.
final class LookVision: @unchecked Sendable {
    struct Analysis: Sendable {
        /// Mean absolute luma change vs the previous frame (0…1) on a 24×24 thumbnail.
        var motion: Double
        /// Salient-object boxes (only when asked for).
        var candidates: [CGRect]
        /// The tracker's box for the highlighted item, and how sure it is (0…1).
        var tracked: CGRect?
        var trackConfidence: Float
        /// The frame as a CGImage for the live view.
        var preview: CGImage?
        /// Frame size in pixels (for aspect-fill mapping in the view).
        var size: CGSize
    }

    struct Crop: Sendable {
        var jpeg: Data
        /// 64-bit dHash of the crop: near-identical crops differ in a few bits.
        var hash: UInt64
    }

    private let queue = DispatchQueue(label: "deal.look.vision", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var previousThumb: [UInt8]?
    private var sequence = VNSequenceRequestHandler()
    private var trackRequest: VNTrackObjectRequest?
    /// Some environments (older Simulators) can't run the tracker. Then the box follows the
    /// salient object with the best overlap instead.
    private var trackerBroken = false
    private var lastTracked: CGRect?

    // MARK: Per frame

    func analyze(_ frame: LookFrame, candidates wantCandidates: Bool) async -> Analysis {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.analyzeNow(frame.pixelBuffer, wantCandidates: wantCandidates)) }
        }
    }

    private func analyzeNow(_ buffer: CVPixelBuffer, wantCandidates: Bool) -> Analysis {
        let image = CIImage(cvPixelBuffer: buffer)
        let size = image.extent.size
        let thumb = gray(image, width: 24, height: 24)
        var motion = 0.0
        if let thumb, let previousThumb, thumb.count == previousThumb.count {
            let sum = zip(thumb, previousThumb).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            motion = Double(sum) / Double(thumb.count) / 255
        }
        previousThumb = thumb

        var tracked: CGRect?
        var confidence: Float = 0
        var salient: [CGRect] = []
        if let request = trackRequest, !trackerBroken {
            do {
                try sequence.perform([request], on: buffer)
                if let obs = request.results?.first as? VNDetectedObjectObservation {
                    request.inputObservation = obs
                    tracked = Self.flip(obs.boundingBox)
                    confidence = obs.confidence
                }
            } catch {
                trackerBroken = true
            }
        }
        if wantCandidates || (trackRequest != nil && trackerBroken) {
            salient = saliency(buffer)
        }
        if trackRequest != nil, trackerBroken, let last = lastTracked {
            // Fallback tracking: the salient box that overlaps the last one the most.
            if let best = salient.max(by: { $0.iou(last) < $1.iou(last) }), best.iou(last) > 0.3 {
                tracked = best
                confidence = Float(best.iou(last))
            }
        }
        if let tracked { lastTracked = tracked }

        let preview = context.createCGImage(image, from: image.extent)
        return Analysis(motion: motion, candidates: salient, tracked: tracked, trackConfidence: confidence,
                        preview: preview, size: size)
    }

    private func saliency(_ buffer: CVPixelBuffer) -> [CGRect] {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let objects = (request.results?.first)?.salientObjects ?? []
        return objects.map { Self.flip($0.boundingBox) }
    }

    // MARK: Tracking

    func startTracking(_ box: CGRect) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: Self.flip(box)))
                request.trackingLevel = .accurate
                self.sequence = VNSequenceRequestHandler()
                self.trackRequest = request
                self.lastTracked = box
                cont.resume()
            }
        }
    }

    func stopTracking() {
        queue.async {
            self.trackRequest?.isLastFrame = true
            self.trackRequest = nil
            self.lastTracked = nil
        }
    }

    // MARK: Crop

    /// JPEG crop of `box` (padded 8%, longest side ≤ `maxDimension`) and its dHash.
    func crop(_ frame: LookFrame, box: CGRect, maxDimension: CGFloat) async -> Crop? {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.cropNow(frame.pixelBuffer, box: box, maxDimension: maxDimension)) }
        }
    }

    private func cropNow(_ buffer: CVPixelBuffer, box: CGRect, maxDimension: CGFloat) -> Crop? {
        let image = CIImage(cvPixelBuffer: buffer)
        let w = image.extent.width, h = image.extent.height
        let padded = box.insetBy(dx: -box.width * 0.08, dy: -box.height * 0.08)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !padded.isNull, padded.width > 0, padded.height > 0 else { return nil }
        // Core Image's origin is bottom-left.
        let rect = CGRect(x: padded.minX * w, y: (1 - padded.maxY) * h, width: padded.width * w, height: padded.height * h).integral
        let cropped = image.cropped(to: rect)
        let moved = cropped.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let scale = min(1, maxDimension / max(rect.width, rect.height))
        let scaled = scale < 1 ? moved.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : moved
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = context.jpegRepresentation(of: scaled, colorSpace: space,
                                                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]),
              let pixels = gray(moved, width: 9, height: 8)
        else { return nil }
        var hash: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                hash <<= 1
                if pixels[row * 9 + col] < pixels[row * 9 + col + 1] { hash |= 1 }
            }
        }
        return Crop(jpeg: jpeg, hash: hash)
    }

    // MARK: Helpers

    /// `image` squashed to `width`×`height` 8-bit luma (Lanczos, so it averages instead of aliasing).
    private func gray(_ image: CIImage, width: Int, height: Int) -> [UInt8]? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let sy = CGFloat(height) / extent.height
        let sx = CGFloat(width) / extent.width
        let small = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
        var out = [UInt8](repeating: 0, count: width * height)
        out.withUnsafeMutableBytes { raw in
            context.render(small, toBitmap: raw.baseAddress!, rowBytes: width, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .L8, colorSpace: nil)
        }
        return out
    }

    /// Vision (origin bottom-left) ↔ overlay (origin top-left). The same flip both ways.
    static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }
}

extension CGRect {
    /// Intersection over union of two boxes (0 when they don't touch).
    func iou(_ other: CGRect) -> CGFloat {
        let i = intersection(other)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = i.width * i.height
        return inter / (width * height + other.width * other.height - inter)
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Moves `fraction` of the way toward `other` (smooths jittery boxes).
    func lerp(_ other: CGRect, _ fraction: CGFloat) -> CGRect {
        CGRect(x: minX + (other.minX - minX) * fraction, y: minY + (other.minY - minY) * fraction,
               width: width + (other.width - width) * fraction, height: height + (other.height - height) * fraction)
    }
}
