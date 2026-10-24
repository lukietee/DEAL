import Foundation
import Observation

/// Display-only output for glanceable cues (Section 4 "Roles": glasses never take input
/// during a negotiation). The Meta wearables SDK implementation (`MetaGlassesDisplay`)
/// arrives tomorrow; `PhoneTeleprompterDisplay` is the fallback.
@MainActor
protocol GlassesDisplay: AnyObject {
    var name: String { get }
    var isConnected: Bool { get }
    /// What is currently shown, so B3's "ON GLASSES" card mirrors it exactly.
    var currentCue: GlassesCue? { get }
    /// Show a cue. Implementations should no-op when `cue.sourceID` is unchanged.
    func show(_ cue: GlassesCue)
    func clear()
}

/// Fallback: a full-screen teleprompter on the buyer's phone (`TeleprompterView`).
/// Always "connected". Also used to mirror the glasses view to a projector.
@MainActor
@Observable
final class PhoneTeleprompterDisplay: GlassesDisplay {
    let name = "Phone teleprompter"
    private(set) var currentCue: GlassesCue?
    /// Increments on every new cue so the view can pulse.
    private(set) var revision = 0

    var isConnected: Bool { true }

    func show(_ cue: GlassesCue) {
        guard cue != currentCue else { return }
        currentCue = cue
        revision += 1
    }

    func clear() {
        currentCue = nil
        revision += 1
    }
}
