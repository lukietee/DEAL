// Meta Ray-Ban Display output via the Meta Wearables Device Access Toolkit (MWDAT 1.0.1).
//
// This file deliberately does NOT import SwiftUI: MWDATDisplay's `Text`, `Image` and `Button`
// would clash with SwiftUI's. SwiftUI-side helpers live in `MetaGlassesUI.swift`.
//
// Lifecycle (mirrors Meta's DisplayAccess sample):
//   Wearables.configure() (lazily, first time the glasses are used, so the Bluetooth /
//   local-network prompts don't appear on every launch) → startRegistration() (opens Meta AI,
//   which calls back on deal://…?metaWearablesAction=…) → AutoDeviceSelector(display-capable)
//   → createSession → session.start() → wait .started → addDisplay() → display.start()
//   → wait DisplayState.started → display.send(FlexBox{…}) on every cue change.
// Each `send` replaces the whole glasses screen. Sends are coalesced to at most ~3 per second.
// If the display stops (temple back gesture, disconnect, session stop) DEAL re-attaches.

import Foundation
import Observation
import UIKit
import MWDATCore
import MWDATDisplay
#if DEBUG
import MWDATMockDevice
#endif

enum MetaGlassesStatus: Equatable, Sendable {
    case off
    case registering
    case searching
    case connecting
    case connected
    case reconnecting
    case failed(String)

    var label: String {
        switch self {
        case .off: "Not connected"
        case .registering: "Waiting for Meta AI…"
        case .searching: "Looking for glasses…"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        case .failed: "Failed"
        }
    }

    var isBusy: Bool {
        switch self {
        case .registering, .searching, .connecting, .reconnecting: true
        default: false
        }
    }
}

@MainActor
@Observable
final class MetaGlassesDisplay: GlassesDisplay {
    let name = "Meta Ray-Ban Display"

    private(set) var status: MetaGlassesStatus = .off
    private(set) var currentCue: GlassesCue?
    private(set) var deviceName: String?
    private(set) var lastError: String?
    private(set) var registrationDescription = "Not configured"
    /// True while the debug MockDeviceKit "phone preview" glasses are in use.
    private(set) var isMock = false

    var isConnected: Bool { status == .connected }
    /// The user asked for the glasses (Connect tapped, or auto-connect at launch).
    private(set) var wantsConnection = false

    // MARK: SDK state (not observed)

    @ObservationIgnored private var configured = false
    @ObservationIgnored private var selector: AutoDeviceSelector?
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var display: Display?
    @ObservationIgnored private var displayStateToken: (any AnyListenerToken)?
    @ObservationIgnored private var sessionTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var registrationTask: Task<Void, Never>?
    @ObservationIgnored private var attachTask: Task<Void, Never>?
    @ObservationIgnored private var readinessTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectAttempts = 0
    /// Bumped on every teardown so stale async work can tell it's obsolete.
    @ObservationIgnored private var generation = 0

    // Send coalescing: `cueRevision` bumps on show/clear, `sentRevision` = last revision on glass.
    @ObservationIgnored private var cueRevision = 0
    @ObservationIgnored private var sentRevision = -1
    @ObservationIgnored private var lastSendAt: ContinuousClock.Instant?
    private static let minSendInterval: Duration = .milliseconds(350)   // ≤ ~3 sends/s
    private static let maxReconnectAttempts = 5
    private static let autoConnectKey = "deal.metaGlasses.autoConnect"

    #if DEBUG
    /// MockDeviceKit's on-phone render of the glasses display (debug builds only).
    private(set) var mockPreview: (any MockDisplayKit)?
    @ObservationIgnored private var mockDevice: (any MockGlasses)?
    #endif

    init() {}

    // MARK: - Public API

    /// Connect at launch if the user connected the glasses before (never on a fresh install,
    /// so the Simulator / UI tests never see Bluetooth prompts).
    func autoConnectIfNeeded() {
        guard !wantsConnection, UserDefaults.standard.bool(forKey: Self.autoConnectKey) else { return }
        connect()
    }

    /// Register with Meta AI if needed, then attach to the display.
    func connect() {
        lastError = nil
        wantsConnection = true
        reconnectAttempts = 0
        if !isMock { UserDefaults.standard.set(true, forKey: Self.autoConnectKey) }
        guard ensureConfigured() else { return }

        let wearables = Wearables.shared
        if wearables.registrationState == .registered {
            attach()
            return
        }
        status = .registering
        Task { [weak self] in
            do {
                try await wearables.startRegistration()
                // Meta AI opens; DEAL resumes via `handleURL`, and the registration stream
                // reports `.registered`, which triggers `attach()`.
            } catch {
                guard let self else { return }
                if let error = error as? RegistrationError, error == .alreadyRegistered {
                    self.attach()
                } else {
                    self.fail("Registration failed: \(Self.describe(error))")
                }
            }
        }
    }

    func disconnect() {
        wantsConnection = false
        UserDefaults.standard.set(false, forKey: Self.autoConnectKey)
        reconnectTask?.cancel()
        reconnectTask = nil
        teardown()
        status = .off
    }

    /// Forget DEAL in Meta AI (re-run registration on next Connect).
    func unregister() {
        disconnect()
        guard configured else { return }
        Task { [weak self] in
            do { try await Wearables.shared.startUnregistration() } catch { self?.lastError = Self.describe(error) }
        }
    }

    /// Route Meta AI callbacks (`deal://…?metaWearablesAction=…`) to the SDK.
    /// Returns false for unrelated URLs.
    @discardableResult
    func handleURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
        else { return false }
        guard ensureConfigured() else { return true }
        Task { [weak self] in
            do {
                _ = try await Wearables.shared.handleUrl(url)
            } catch {
                self?.fail("Meta AI callback failed: \(Self.describe(error))")
            }
        }
        return true
    }

    func show(_ cue: GlassesCue) {
        guard cue != currentCue else { return }
        currentCue = cue
        cueRevision += 1
        if wantsConnection, display == nil, attachTask == nil, reconnectTask == nil, session == nil {
            attach()   // e.g. the user swiped back out of DEAL: a new cue brings it back
        }
        scheduleSend()
    }

    func clear() {
        guard currentCue != nil else { return }
        currentCue = nil
        cueRevision += 1
        scheduleSend()
    }

    // MARK: - Configure + registration

    private func ensureConfigured() -> Bool {
        if configured { return true }
        do {
            try Wearables.configure()
        } catch {
            if error != .alreadyConfigured {
                fail("Wearables SDK setup failed: \(error.description)")
                return false
            }
        }
        configured = true
        registrationDescription = Wearables.shared.registrationState.description
        observeRegistration()
        return true
    }

    private func observeRegistration() {
        registrationTask?.cancel()
        let wearables = Wearables.shared
        registrationTask = Task { [weak self] in
            for await state in wearables.registrationStateStream() {
                guard let self, !Task.isCancelled else { return }
                self.registrationDescription = state.description
                switch state {
                case .registered:
                    if self.wantsConnection, self.session == nil, self.attachTask == nil { self.attach() }
                case .available, .unavailable:
                    // Unregistered (or Meta AI gone): drop any session; selector must be rebuilt.
                    if self.session != nil || self.status == .connected {
                        self.teardown()
                        self.selector = nil
                        if self.wantsConnection { self.status = .off }
                    }
                case .registering:
                    if self.wantsConnection, self.status != .connected { self.status = .registering }
                @unknown default:
                    break
                }
            }
        }
    }

    // MARK: - Attach / detach

    private func attach() {
        guard wantsConnection, session == nil, attachTask == nil else { return }
        let gen = generation
        status = reconnectAttempts > 0 ? .reconnecting : .searching
        attachTask = Task { [weak self] in
            await self?.runAttach(gen)
            self?.attachTask = nil
        }
    }

    private func runAttach(_ gen: Int) async {
        let wearables = Wearables.shared
        let selector = self.selector ?? AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
        self.selector = selector

        // AutoDeviceSelector fills in from devicesStream(); createSession throws
        // noEligibleDevice until it has picked one. Poll (cheap, cancellation-safe).
        guard let deviceID = await waitFor(seconds: 15, { selector.activeDevice }) else {
            guard gen == generation else { return }
            fail("No Meta Ray-Ban Display found. Check the glasses are on, connected in Meta AI, and Developer Mode is on.")
            return
        }
        guard gen == generation, wantsConnection else { return }

        if let device = wearables.deviceForIdentifier(deviceID) {
            deviceName = device.nameOrId()
            if device.compatibility() == .deviceUpdateRequired {
                fail("Glasses firmware update required. Update the glasses in the Meta AI app.")
                return
            }
            // Give the link a moment to come up (mirrors the sample's readiness check).
            _ = await waitFor(seconds: 5, {
                let d = wearables.deviceForIdentifier(deviceID)
                return d?.linkState == .connected ? true : nil
            })
            guard gen == generation, wantsConnection else { return }
        }

        status = .connecting
        let session: DeviceSession
        do {
            session = try wearables.createSession(deviceSelector: selector)
        } catch {
            fail("Couldn't start a glasses session: \(error.description)")
            return
        }
        self.session = session

        let states = session.stateStream()
        let errors = session.errorStream()
        sessionTasks.append(Task { [weak self] in
            for await state in states {
                guard let self, !Task.isCancelled, self.session === session else { return }
                switch state {
                case .started:
                    self.setupDisplay(on: session)
                case .stopped:
                    self.connectionLost("Glasses session stopped")
                default:
                    break
                }
            }
        })
        sessionTasks.append(Task { [weak self] in
            for await error in errors {
                guard let self, !Task.isCancelled, self.session === session else { return }
                switch error {
                case .datAppOnTheGlassesUpdateRequired:
                    self.fail("The DEAL/DAT app on the glasses needs an update (Meta AI app).")
                case .thermalCritical, .thermalEmergency, .batteryCritical, .peakPowerShutdown:
                    self.fail("Glasses: \(error.description)")
                case .dwaOutOfStuRange:
                    break   // non-blocking compatibility warning
                default:
                    self.lastError = error.description
                }
            }
        })

        // If the display isn't up in 15 s, start over.
        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, self.session === session, !self.isConnected else { return }
            self.connectionLost("Timed out waiting for the glasses display")
        }

        do {
            try session.start()
        } catch {
            if error == .datAppOnTheGlassesUpdateRequired {
                fail("The app on the glasses needs an update (Meta AI app).")
            } else {
                connectionLost("Session start failed: \(error.description)")
            }
        }
    }

    private func setupDisplay(on session: DeviceSession) {
        guard display == nil, self.session === session else { return }
        do {
            let display = try session.addDisplay()
            self.display = display
            displayStateToken = display.statePublisher.listen { [weak self] state in
                Task { @MainActor [weak self] in self?.handleDisplayState(state, from: display) }
            }
            display.start()
        } catch {
            connectionLost("Couldn't add the display: \(error.description)")
        }
    }

    private func handleDisplayState(_ state: DisplayState, from display: Display) {
        guard display === self.display else { return }
        switch state {
        case .started:
            readinessTask?.cancel()
            readinessTask = nil
            reconnectAttempts = 0
            lastError = nil
            status = .connected
            sentRevision = -1          // fresh screen: resend the current cue (or standby card)
            scheduleSend()
        case .stopping:
            if status == .connected { status = .reconnecting }
        case .stopped:
            // Temple back gesture, glasses took the display, or the link dropped.
            connectionLost(nil)
        case .starting:
            break
        @unknown default:
            break
        }
    }

    /// Drop everything and, if the user still wants the glasses, re-attach with backoff.
    private func connectionLost(_ reason: String?) {
        if let reason { lastError = reason }
        teardown()
        guard wantsConnection else { status = .off; return }
        reconnectAttempts += 1
        guard reconnectAttempts <= Self.maxReconnectAttempts else {
            status = .failed(reason ?? "Lost the glasses")
            lastError = (reason ?? "Lost the glasses") + ". Tap Connect glasses to retry."
            return
        }
        status = .reconnecting
        let delay = Double(min(reconnectAttempts, 4))   // 1, 2, 3, 4, 4 s
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.attach()
        }
    }

    private func fail(_ message: String) {
        teardown()
        lastError = message
        status = .failed(message)
    }

    private func teardown() {
        generation += 1
        attachTask?.cancel()
        attachTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        sessionTasks.forEach { $0.cancel() }
        sessionTasks = []
        displayStateToken = nil   // dropping the token stops the listener
        if let display {
            self.display = nil
            display.stop()
        }
        if let session {
            self.session = nil
            session.stop()
        }
        sendTask?.cancel()
        sendTask = nil
    }

    private static func describe(_ error: any Error) -> String {
        (error as? any DatError)?.description ?? error.localizedDescription
    }

    private func waitFor<T>(seconds: Double, _ probe: () -> T?) async -> T? {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if let value = probe() { return value }
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return probe()
    }

    // MARK: - Sending

    private func scheduleSend() {
        guard sendTask == nil, display != nil, isConnected else { return }
        sendTask = Task { [weak self] in
            await self?.sendLoop()
            self?.sendTask = nil
        }
    }

    /// Sends the newest cue, then keeps going while newer cues arrived during the send.
    private func sendLoop() async {
        while !Task.isCancelled, isConnected, let display, sentRevision != cueRevision {
            if let last = lastSendAt {
                let wait = Self.minSendInterval - (ContinuousClock.now - last)
                if wait > .zero { try? await Task.sleep(for: wait) }
            }
            guard !Task.isCancelled, isConnected, display === self.display else { return }
            let revision = cueRevision
            let isFreshScreen = sentRevision == -1
            let cue = currentCue
            lastSendAt = .now
            do {
                if let cue {
                    try await display.send(Self.layout(for: cue))
                } else if isFreshScreen {
                    try await display.send(Self.standbyLayout())
                } else {
                    try await display.clearDisplay()
                }
                sentRevision = revision
            } catch {
                if let displayError = error as? DisplayError, displayError == .deviceDisconnected {
                    connectionLost("Glasses disconnected")
                } else {
                    lastError = (error as? DisplayError)?.description ?? error.localizedDescription
                    sentRevision = revision   // don't hot-loop on a bad payload
                }
                return
            }
        }
    }

    // MARK: - Layout (one root FlexBox per send)

    /// Status dot + status word, cue heading, optional detail, offer → target.
    /// The display only has primary/secondary text colors, so the status color is a small
    /// bright dot image (additive optics: black would be invisible) and the status word.
    static func layout(for cue: GlassesCue) -> FlexBox {
        let statusWord = cue.isAlert ? "ALERT" : (cue.status == .unknown ? "CUE" : cue.status.label.uppercased())
        let offer = "Offer \(Money.format(cue.currentOffer, placeholder: "—"))"
        let target = "Target \(Money.format(cue.target))"
        let detail = cue.detail.flatMap { $0.isEmpty ? nil : $0 }
        return FlexBox(direction: .column, spacing: 10) {
            FlexBox(direction: .row, spacing: 8, crossAlignment: .center) {
                Image(image: statusDot(cue.isAlert ? .red : cue.status), sizePreset: .icon)
                Text(statusWord, style: .meta, color: .secondary)
            }
            Text(cue.text, style: .heading)
            if let detail {
                Text(detail, style: .body)
            }
            FlexBox(direction: .row, spacing: 16) {
                Text(offer, style: .body)
                Text(target, style: .body, color: .secondary)
            }
        }
        .padding(20)
        .background(.card)
    }

    static func standbyLayout() -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            FlexBox(direction: .row, spacing: 8, crossAlignment: .center) {
                Image(image: statusDot(.green), sizePreset: .icon)
                Text("DEAL", style: .meta, color: .secondary)
            }
            Text("Glasses connected", style: .heading)
            Text("Cues appear here during a negotiation", style: .body, color: .secondary)
        }
        .padding(20)
        .background(.card)
    }

    private static var dotCache: [StatusColor: UIImage] = [:]

    static func statusDot(_ status: StatusColor) -> UIImage {
        if let cached = dotCache[status] { return cached }
        let color: UIColor = switch status {
        case .green: UIColor(red: 0.25, green: 1.0, blue: 0.45, alpha: 1)
        case .yellow: UIColor(red: 1.0, green: 0.86, blue: 0.15, alpha: 1)
        case .red: UIColor(red: 1.0, green: 0.28, blue: 0.28, alpha: 1)
        case .unknown: UIColor(white: 0.85, alpha: 1)
        }
        let size = CGSize(width: 32, height: 32)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)).fill()
        }
        dotCache[status] = image
        return image
    }

    // MARK: - Debug: MockDeviceKit phone preview

    #if DEBUG
    /// Pair a simulated Meta Ray-Ban Display (MockDeviceKit) and connect to it. The real
    /// Display session runs against it; `mockPreview` renders what the glasses would show.
    func enableMockGlasses() async {
        guard mockDevice == nil else { return }
        disconnect()
        guard ensureConfigured() else { return }
        let kit = MockDeviceKit.shared
        kit.enable()   // default config: initially registered, permissions granted
        do {
            let device = try kit.pairGlasses(model: .metaRayBanDisplay)
            device.powerOn()
            device.don()
            mockDevice = device
            mockPreview = device.services.display
            isMock = true
            selector = nil
            let id = device.deviceIdentifier
            _ = await waitFor(seconds: 3, {
                let d = Wearables.shared.deviceForIdentifier(id)
                return (d?.linkState == .connected && d?.compatibility() == .compatible) ? true : nil
            })
            connect()
        } catch {
            await kit.disable()
            fail("Mock glasses failed: \(error.description)")
        }
    }

    func disableMockGlasses() {
        disconnect()
        if let mockDevice { MockDeviceKit.shared.unpairDevice(mockDevice) }
        MockDeviceKit.shared.disable()
        mockDevice = nil
        mockPreview = nil
        isMock = false
        selector = nil
        deviceName = nil
    }
    #endif
}
