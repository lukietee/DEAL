// Look mode gestures from the glasses (MWDATInputs 1.0.1, experimental).
//
// Rides on MetaGlassesDisplay's DeviceSession as a session client: on every `.started` it
// runs session.addInputs(configuration:) and reads `inputs.events`; on teardown
// session.removeInputs(). `consumeBack: true` so a back gesture dismisses the Look card
// instead of closing DEAL on the glasses.
//
// Mapping: select (Neural Band pinch / captouch tap) → .select; back → .dismiss;
// nav right/down → .next, left/up → .previous; capture button hold → .negotiate.
// Drag, the action button and other capture presses are ignored.
//
// `PhoneGestureSource` lets on-screen buttons inject the same gestures (no glasses), and
// `MergedGestureSource` combines both so Look takes one source either way.

import Foundation
import Observation
import MWDATCore
import MWDATInputs

@MainActor
@Observable
final class GlassesInputs: LookGestureSource {
    private(set) var isActive = false
    /// SDK input state ("inactive", "activating", "active"…), for a status line.
    private(set) var stateDescription = "inactive"
    private(set) var lastError: String?
    @ObservationIgnored var onGesture: ((LookGesture) -> Void)?

    static let configuration = InputsConfiguration(sources: [.neuralBand, .captouch, .captureButton],
                                                   consumeBack: true)
    private static let clientKey = "look.inputs"

    private let glasses: MetaGlassesDisplay
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var inputs: Inputs?
    @ObservationIgnored private var tokens: [any AnyListenerToken] = []
    @ObservationIgnored private var eventsTask: Task<Void, Never>?

    init(glasses: MetaGlassesDisplay) {
        self.glasses = glasses
    }

    /// Throws if the glasses aren't connected (or connecting). Events start once the
    /// session is up, and resume by themselves after a reconnect.
    func start() async throws {
        guard !isActive else { return }
        guard glasses.wantsConnection else { throw LookSourceError.glassesNotConnected }
        isActive = true
        lastError = nil
        glasses.addSessionClient(Self.clientKey,
                                 attach: { [weak self] session in self?.attach(to: session) },
                                 detach: { [weak self] in self?.detach() })
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        glasses.removeSessionClient(Self.clientKey)
        detach()
    }

    private func attach(to session: DeviceSession) {
        detach()
        let inputs: Inputs
        do {
            if let added = try Self.addInputs(to: session) {
                inputs = added
            } else {
                lastError = "These glasses don't report input events"
                return
            }
        } catch {
            lastError = "Couldn't add glasses inputs: \(error.description)"
            return
        }
        self.session = session
        self.inputs = inputs
        stateDescription = inputs.state.description
        tokens.append(inputs.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.inputs === inputs else { return }
                self.stateDescription = state.description
            }
        })
        tokens.append(inputs.errorPublisher.listen { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.inputs === inputs else { return }
                self.lastError = error.description
            }
        })
        let events = inputs.events
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled, self.inputs === inputs else { return }
                guard let gesture = Self.gesture(for: event) else { continue }
                self.onGesture?(gesture)
            }
        }
    }

    /// One Inputs per session: if a stale one is still registered, remove it and retry once.
    private static func addInputs(to session: DeviceSession) throws(DeviceSessionError) -> Inputs? {
        do {
            return try session.addInputs(configuration: configuration)
        } catch .capabilityAlreadyActive {
            try? session.removeInputs()
            return try session.addInputs(configuration: configuration)
        }
    }

    private func detach() {
        eventsTask?.cancel()
        eventsTask = nil
        tokens = []
        if let session, inputs != nil {
            try? session.removeInputs()
        }
        inputs = nil
        session = nil
        stateDescription = "inactive"
    }

    static func gesture(for event: InputEvent) -> LookGesture? {
        switch event {
        case .select:
            .select
        case .back:
            .dismiss
        case .nav(let direction, _, _):
            switch direction {
            case .right, .down: .next
            case .left, .up: .previous
            }
        case .capture(let press, _, _):
            press == .hold ? .negotiate : nil
        case .button, .drag:
            nil
        @unknown default:
            nil
        }
    }
}

/// On-screen buttons (or tests) inject gestures directly. Always available.
@MainActor
final class PhoneGestureSource: LookGestureSource {
    private(set) var isActive = false
    var onGesture: ((LookGesture) -> Void)?

    func start() async throws { isActive = true }
    func stop() { isActive = false }

    func send(_ gesture: LookGesture) {
        guard isActive else { return }
        onGesture?(gesture)
    }
}

/// Fans several sources into one: e.g. glasses inputs + phone buttons. Starts every source
/// it can; only throws if none of them start.
@MainActor
final class MergedGestureSource: LookGestureSource {
    let sources: [any LookGestureSource]
    var onGesture: ((LookGesture) -> Void)?

    init(_ sources: [any LookGestureSource]) {
        self.sources = sources
        for source in sources {
            source.onGesture = { [weak self] gesture in self?.onGesture?(gesture) }
        }
    }

    var isActive: Bool { sources.contains { $0.isActive } }

    func start() async throws {
        var firstError: (any Error)?
        for source in sources {
            do { try await source.start() } catch { firstError = firstError ?? error }
        }
        if !isActive, let firstError { throw firstError }
    }

    func stop() {
        sources.forEach { $0.stop() }
    }
}
