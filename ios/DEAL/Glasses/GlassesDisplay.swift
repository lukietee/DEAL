import Foundation
import Observation

/// Display-only output for glanceable cues (Section 4 "Roles": glasses never take input
/// during a negotiation). Implementations: `MetaGlassesDisplay` (Ray-Ban Meta Display via the
/// Meta Wearables SDK) and `PhoneTeleprompterDisplay` (fallback). `GlassesFanOut` drives both.
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

/// Sends every cue to the phone teleprompter (always on, so B3 / the projector mirror never
/// go blank) and to the Meta glasses (when connected; it no-ops or queues otherwise).
@MainActor
@Observable
final class GlassesFanOut: GlassesDisplay {
    let phone: PhoneTeleprompterDisplay
    let meta: MetaGlassesDisplay

    init(phone: PhoneTeleprompterDisplay, meta: MetaGlassesDisplay) {
        self.phone = phone
        self.meta = meta
    }

    var name: String { meta.isConnected ? "\(meta.name) + phone" : phone.name }
    var isConnected: Bool { true }
    var currentCue: GlassesCue? { phone.currentCue }

    func show(_ cue: GlassesCue) {
        phone.show(cue)
        meta.show(cue)
    }

    func clear() {
        phone.clear()
        meta.clear()
    }
}
