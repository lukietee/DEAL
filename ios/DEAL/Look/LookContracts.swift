// "Look" mode: look at a product (e.g. The Weeknd "Starboy" vinyl), DEAL highlights it in
// green with a small price window above it, and a Neural Band gesture acts on it.
//
// Shared contract between the three pieces, so they can be built in parallel:
//   - Glasses I/O (Look/GlassesCamera.swift, Look/GlassesInputs.swift): frames + gestures.
//   - Scanner + UI (Look/LookScanner.swift, Look/LookView.swift): dwell gating, overlay.
//   - Backend: POST /look/identify and POST /look/price (see backend/src/routes/look.ts).
// Change these types only by agreement; every piece compiles against them.

import CoreGraphics
import CoreVideo
import Foundation

// MARK: Frames

/// One camera frame. `pixelBuffer` is upright (orientation already applied).
struct LookFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let timestamp: TimeInterval
}

/// Where frames come from: the glasses camera (MWDATCamera), the MockDeviceKit feed, or the
/// iPhone's back camera as a fallback (Simulator, no glasses).
@MainActor
protocol LookFrameSource: AnyObject {
    var name: String { get }
    var isRunning: Bool { get }
    /// Called on the main actor, at most ~10 fps (implementations drop frames to keep up).
    var onFrame: ((LookFrame) -> Void)? { get set }
    func start() async throws
    func stop()
}

// MARK: Gestures

/// Glasses input mapped to what Look mode cares about. Neural Band pinch → `.select`,
/// swipes → `.next`/`.previous`, back (middle-finger pinch / temple swipe) → `.dismiss`,
/// capture button hold → `.negotiate`.
enum LookGesture: Equatable, Sendable {
    case select    // expand the highlighted item: full market research
    case dismiss   // hide it and don't re-highlight this item for a while
    case next      // cycle sources / price details
    case previous
    case negotiate // start a negotiation session for this item
}

@MainActor
protocol LookGestureSource: AnyObject {
    var isActive: Bool { get }
    var onGesture: ((LookGesture) -> Void)? { get set }
    func start() async throws
    func stop()
}

// MARK: Backend (snake_case on the wire, decoded with APIClient.decoder)

/// POST /look/identify  {image_base64 (JPEG crop, ≤ 768 px), hint?: String}
struct LookIdentification: Codable, Equatable, Sendable {
    /// False for people, walls, generic furniture, screens… anything not worth pricing.
    let isProduct: Bool
    /// e.g. "The Weeknd – Starboy (2×LP vinyl)"
    let name: String?
    let category: String?
    /// 0…1. The scanner only highlights at ≥ 0.6.
    let confidence: Double
}

/// POST /look/price  {name, category?}. Fast (cached per name), not the full research run.
struct LookPrice: Codable, Equatable, Sendable {
    let name: String
    let priceLow: Int?  // cents
    let priceHigh: Int? // cents
    /// One short line, e.g. "Used $22–30 · new $35"
    let summary: String
    let sourceCount: Int
}

// MARK: What the overlay and the glasses show

struct LookHighlight: Equatable, Sendable {
    let id: UUID
    /// Normalized (0…1, origin top-left) box of the item in the current frame.
    var box: CGRect
    var identification: LookIdentification
    var price: LookPrice?
    var expanded: Bool = false
}
