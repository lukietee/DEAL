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
    /// Listening sessions default to Auto (the backend decides who spoke); You / Seller force it.
    var micSpeaker: MicSpeaker = .buyer
    private var transcriber: SpeechTranscriber?
    /// Set by B1 "Start listening": B3 turns the mic on as soon as it appears (once).
    var autoStartMic = false
    /// UI tests pass this so the Simulator never shows the speech / mic permission prompts.
    nonisolated static let noAutoMicLaunchArgument = "-DEALNoAutoMic"

    var syncDescription: String { sync.modeDescription }

    // Marketplace
    /// The listing imported in B2, in case the backend doesn't echo `session.listing`.
    var fallbackListing: Listing?
    var listing: Listing? { state.listing ?? fallbackListing }
    var isMarketplace: Bool { state.isMarketplace || fallbackListing != nil }
    /// Condition mismatches found on this phone (B3 "Check condition"), newest first.
    private(set) var localDiscrepancies: [Discrepancy] = []
    /// Every known mismatch: this phone's checks plus any the backend persisted, newest first.
    var discrepancies: [Discrepancy] {
        var seen = Set<String>()
        return (localDiscrepancies + state.storedDiscrepancies.reversed()).filter { seen.insert($0.id).inserted }
    }
    private(set) var isCheckingCondition = false

    // Glasses research strip (see `pushResearchStrip`)
    private var researchStrip: GlassesResearch?
    private var researchHoldUntil = Date.distantPast
    private var lastCueID: String?
    private var lastCueAt = Date.distantPast
    private var researchStripTask: Task<Void, Never>?
    /// How long the strip stays up when research starts or an agent finishes.
    nonisolated static let researchHold: TimeInterval = 5
    /// While research runs, the strip comes back once no new cue has arrived for this long.
    nonisolated static let researchCueQuiet: TimeInterval = 6

    init(role: Speaker, initial: SessionState, api: APIClient, sync: SessionSync, glasses: GlassesDisplay?) {
        self.role = role
        self.state = initial
        self.api = api
        self.sync = sync
        self.glasses = glasses
        self.micSpeaker = initial.session.auto ? .auto : .buyer
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
        researchStripTask?.cancel()
        researchStripTask = nil
        if role == .buyer {
            glasses?.showResearch(nil)
            glasses?.showMarket(nil)
            glasses?.clear()
        }
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
        let now = Date()
        if let cue = state.glassesCue {
            if cue.sourceID != lastCueID {
                // A fresh cue is what the buyer needs right now: it ends any strip hold.
                lastCueID = cue.sourceID
                lastCueAt = now
                researchHoldUntil = now
            }
            glasses.show(cue)
        }
        glasses.showMarket(GlassesMarket(state.research))
        let strip = GlassesResearch(state.research)
        if let strip {
            // Hold the strip when research starts (or restarts) and each time an agent finishes.
            let previous = researchStrip
            if previous == nil ? strip.isRunning : strip.doneCount != previous!.doneCount {
                researchHoldUntil = now.addingTimeInterval(Self.researchHold)
            }
        }
        researchStrip = strip
        pushResearchStrip()
    }

    /// The research strip covers the cue while the three agents work, as long as the conversation
    /// is quiet (no new cue for `researchCueQuiet`), and for `researchHold` after research starts
    /// or an agent finishes with its headline. Otherwise the live cue shows.
    private func pushResearchStrip() {
        researchStripTask?.cancel()
        researchStripTask = nil
        guard role == .buyer, let glasses else { return }
        let now = Date()
        guard let strip = researchStrip else {
            glasses.showResearch(nil)
            return
        }
        let quietAt = lastCueAt.addingTimeInterval(Self.researchCueQuiet)
        let held = now < researchHoldUntil
        let quiet = strip.isRunning && now >= quietAt
        glasses.showResearch(held || quiet ? strip : nil)

        // Re-check at the next moment the answer can change on its own.
        let next = [researchHoldUntil, strip.isRunning ? quietAt : .distantPast].filter { $0 > now }.min()
        guard let next else { return }
        researchStripTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSince(now) + 0.05))
            guard !Task.isCancelled else { return }
            self?.pushResearchStrip()
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

    /// B3 Research panel "Run again".
    func restartResearch() async {
        _ = await perform { try await api.restartResearch(sessionID: session.id) }
    }

    /// B3 "Check condition". Errors are thrown back to the sheet instead of the session banner.
    func checkCondition(observation: String?, imageBase64: String?) async throws -> ConditionCheckResult {
        let text = observation?.trimmingCharacters(in: .whitespacesAndNewlines)
        isCheckingCondition = true
        defer { isCheckingCondition = false }
        let result = try await api.conditionCheck(sessionID: session.id,
                                                  observation: (text?.isEmpty ?? true) ? nil : text,
                                                  imageBase64: imageBase64)
        let existing = Set(localDiscrepancies.map(\.id))
        localDiscrepancies.insert(contentsOf: result.discrepancies.filter { !existing.contains($0.id) }, at: 0)
        // Show the inserted cue event right away (on B3 and the glasses); the next sync confirms it.
        if let event = result.event, !event.id.isEmpty, !state.events.contains(where: { $0.id == event.id }) {
            state.events.append(event)
            pushGlasses()
        }
        sync.refreshNow()
        return result
    }

    func postTranscriptLine(_ text: String, speaker: MicSpeaker) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = await perform { try await api.postEvent(sessionID: session.id, speaker: speaker, text: trimmed) }
    }

    func fixTerm(_ term: Term, correction: TermCorrection) async {
        _ = await perform { try await api.fixTerm(sessionID: session.id, termID: term.id, correction: correction) }
    }

    /// B3 "End": stops the mic, ends the conversation on the backend and returns the session with
    /// its `summary`. Sync keeps running so the summary sheet can still show fresh state.
    func endConversation() async -> Session? {
        stopMic()
        guard let ended = await perform({ try await api.endSession(sessionID: session.id) }) else { return nil }
        state.session = ended
        return ended
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
