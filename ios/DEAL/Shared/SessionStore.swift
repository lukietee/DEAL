import Foundation
import Observation

/// One live session on this phone (buyer or seller). Owns sync, exposes derived state,
/// and performs every write through `APIClient`.
@MainActor
@Observable
final class SessionStore {
    let role: Speaker
    let api: APIClient
    private let sync: SessionSync
    private let glasses: GlassesDisplay?

    private(set) var state: SessionState
    /// Error from the last user action (sticky until dismissed or the next action succeeds).
    private(set) var lastError: String?
    /// Sync/connection error; clears automatically on the next successful sync.
    private(set) var syncError: String?
    /// What the error banner shows.
    var bannerMessage: String? { lastError ?? syncError.map { "Connection problem: \($0)" } }
    private(set) var isBusy = false
    private(set) var lastSyncedAt: Date?
    private(set) var connectionOK = true

    // Buyer-side live mic / scripted mode
    /// True once this phone asked the backend to play a script, or the backend reports a run.
    var scriptStarted: Bool { requestedScript || state.script != nil }
    private var requestedScript = false
    private(set) var isListening = false
    private(set) var partialTranscript = ""
    var micSpeaker: Speaker = .buyer
    private var transcriber: SpeechTranscriber?

    var syncDescription: String { sync.modeDescription }

    init(role: Speaker, initial: SessionState, api: APIClient, sync: SessionSync, glasses: GlassesDisplay?) {
        self.role = role
        self.state = initial
        self.api = api
        self.sync = sync
        self.glasses = glasses
        pushGlasses()
    }

    convenience init(role: Speaker, session: Session, api: APIClient, sync: SessionSync, glasses: GlassesDisplay?) {
        self.init(role: role, initial: SessionState(session: session), api: api, sync: sync, glasses: glasses)
    }

    var session: Session { state.session }

    func startSync() {
        sync.start(sessionID: state.session.id, onState: { [weak self] new in
            self?.apply(new)
        }, onError: { [weak self] error in
            self?.connectionOK = false
            self?.syncError = error.localizedDescription
        })
    }

    func stopAll() {
        sync.stop()
        stopMic()
        if role == .buyer { glasses?.clear() }
    }

    func apply(_ new: SessionState) {
        connectionOK = true
        syncError = nil
        lastSyncedAt = Date()
        guard new != state else { return }
        state = new
        pushGlasses()
    }

    func clearError() { lastError = nil; syncError = nil }

    private func pushGlasses() {
        guard role == .buyer, let glasses else { return }
        if let cue = state.glassesCue {
            glasses.show(cue)
        }
    }

    // MARK: - Writes

    private func perform<T>(_ op: () async throws -> T) async -> T? {
        isBusy = true
        defer { isBusy = false }
        do {
            let value = try await op()
            lastError = nil
            sync.refreshNow()
            return value
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// B3 Scripted mode: backend inserts script lines as events on a timer.
    func playScript(scriptID: String? = nil) async {
        let id = scriptID ?? session.category.defaultScriptID
        let result = await perform { try await api.playScript(sessionID: session.id, scriptID: id) }
        if result != nil { requestedScript = true }
    }

    func postTranscriptLine(_ text: String, speaker: Speaker) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = await perform { try await api.postEvent(sessionID: session.id, speaker: speaker, text: trimmed) }
    }

    func fixTerm(_ term: Term, correction: TermCorrection) async {
        _ = await perform { try await api.fixTerm(sessionID: session.id, termID: term.id, correction: correction) }
    }

    /// B3 "Lock Deal": drafts the agreement from the transcript.
    func lockDeal() async {
        stopMic()
        if let agreement = await perform({ try await api.draftAgreement(sessionID: session.id) }) {
            state.agreement = agreement
        }
    }

    /// B4 / S3 Confirm.
    func confirmAgreement() async {
        guard let agreement = state.agreement else { return }
        if let updated = await perform({ try await api.confirmAgreement(id: agreement.id, role: role) }) {
            state.agreement = updated
        }
    }

    /// B5 decision.
    func decide(_ request: PaymentRequest, _ decision: PaymentDecision) async {
        if let updated = await perform({ try await api.decide(paymentRequestID: request.id, decision: decision) }) {
            replace(updated)
        }
    }

    /// S4 "+ Add line item": the agreement's line items plus one extra -> expected `blocked`.
    func addLineItem(label: String, amount: Int) async {
        let items = state.agreedLineItems + [LineItem(label: label, amount: amount)]
        if let pr = await perform({ try await api.createPaymentRequest(sessionID: session.id, lineItems: items) }) {
            replace(pr)
        }
    }

    /// S4 "Tap to Pay" (after the simulated tap animation). Uses an already-approved request if
    /// one exists (e.g. buyer approved an amendment), otherwise submits the agreed line items.
    /// Returns true when a receipt was produced.
    @discardableResult
    func chargeAgreedAmount() async -> Bool {
        var request: PaymentRequest?
        if case .approved(let approved) = state.terminalState {
            request = approved
        } else {
            request = await perform { try await api.createPaymentRequest(sessionID: session.id, lineItems: state.agreedLineItems) }
            if let request { replace(request) }
        }
        guard let request else { return false }
        guard request.status == .approved else {
            if request.status == .blocked {
                lastError = request.mismatchExplanation ?? "Charge blocked: it doesn't match the agreement."
            }
            return false
        }
        if let receipt = await perform({ try await api.pay(paymentRequestID: request.id) }) {
            state.receipt = receipt
            return true
        }
        return false
    }

    private func replace(_ pr: PaymentRequest) {
        if let i = state.paymentRequests.firstIndex(where: { $0.id == pr.id }) {
            state.paymentRequests[i] = pr
        } else {
            state.paymentRequests.append(pr)
        }
        pushGlasses()
    }

    // MARK: - Live mic

    func startMic(using transcriber: SpeechTranscriber) async {
        guard !isListening else { return }
        guard await transcriber.requestAuthorization() else {
            lastError = SpeechError.notAuthorized.localizedDescription
            return
        }
        do {
            try transcriber.start(onPartial: { [weak self] partial in
                self?.partialTranscript = partial
            }, onUtterance: { [weak self] phrase in
                guard let self else { return }
                let speaker = self.micSpeaker
                Task { await self.postTranscriptLine(phrase, speaker: speaker) }
            })
            self.transcriber = transcriber
            isListening = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopMic() {
        transcriber?.stop()
        transcriber = nil
        isListening = false
        partialTranscript = ""
    }
}
