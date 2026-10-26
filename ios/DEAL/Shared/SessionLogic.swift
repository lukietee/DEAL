import Foundation

// Pure, Foundation-only derivations over `SessionState`. No UI, no I/O, unit-testable.

enum BuyerPhase: Equatable, Sendable {
    /// B3: negotiating.
    case live
    /// B4: agreement drafted, not yet locked (or locked and waiting for the seller to charge).
    case agreement
    /// B6: paid.
    case receipt
}

enum SellerPhase: Equatable, Sendable {
    /// S2: watching the negotiation (no cues, no transcript).
    case live
    /// S3: agreement drafted, waiting for confirmations.
    case agreement
    /// S4: agreement locked -> terminal.
    case terminal
    /// S5: paid.
    case receipt
}

/// State of the seller terminal (S4).
enum TerminalState: Equatable, Sendable {
    /// No outstanding request: ready to tap and charge the agreed amount.
    case ready
    /// A request with extra items is blocked, waiting for the buyer (B5).
    case waitingForBuyer(PaymentRequest)
    /// Buyer rejected the change; seller should charge the agreed amount.
    case rejected(PaymentRequest)
    /// An approved request is ready to be paid (amount may be amended).
    case approved(PaymentRequest)
}

/// The glasses research strip: one row per research agent (Comps / Issues / Price) with its
/// progress, then its headline once it finishes. `SessionStore` decides when it covers the cue.
struct GlassesResearch: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case working, done, failed }

    struct Row: Equatable, Sendable {
        let label: String
        let phase: Phase
        let text: String
    }

    let rows: [Row]
    let isRunning: Bool

    var doneCount: Int { rows.filter { $0.phase != .working }.count }

    init?(_ research: ResearchState?) {
        guard let research, !research.agents.isEmpty else { return nil }
        rows = research.agents.map { agent in
            let label = switch agent.id {
            case "comps": "Comps"
            case "issues": "Issues"
            case "price": "Price"
            default: agent.title
            }
            switch agent.status {
            case "done":
                let range = agent.priceLow.flatMap { low in agent.priceHigh.map { "\(Money.format(low))–\(Money.format($0))" } }
                return Row(label: label, phase: .done, text: agent.headline ?? range ?? "Done")
            case "error":
                return Row(label: label, phase: .failed, text: "Unavailable")
            case "reading":
                return Row(label: label, phase: .working, text: "Reading…")
            default:
                return Row(label: label, phase: .working, text: "Searching…")
            }
        }
        isRunning = research.isRunning
    }
}

struct GlassesCue: Equatable, Sendable {
    var text: String
    var detail: String?
    var status: StatusColor
    var currentOffer: Int?
    /// nil when the session has no target (listening sessions).
    var target: Int?
    var isAlert: Bool = false
    /// Identity of what triggered the cue, so displays only update on change.
    var sourceID: String
}

enum OfferProgressLabel: String, Sendable {
    case noOffer = "no offer yet"
    case far = "far from target"
    case closing = "closing in"
    case near = "near target"
    case atTarget = "at or below target"
    case overBudget = "over max budget"
}

extension SessionState {
    var sortedEvents: [DealEvent] {
        events.enumerated().sorted { a, b in
            switch (a.element.seq, b.element.seq) {
            case let (x?, y?) where x != y: return x < y
            default: break
            }
            switch (a.element.timestamp, b.element.timestamp) {
            case let (x?, y?) where x != y: return x < y
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    func event(id: String?) -> DealEvent? {
        guard let id else { return nil }
        return events.first { $0.id == id || $0.scriptLineId == id }
    }

    /// Prefers the session's server-tracked offer; falls back to the latest extracted offer.
    var currentOffer: Int? {
        session.currentOffer ?? sortedEvents.last(where: { $0.extractedOffer != nil })?.extractedOffer
    }

    var currentOfferBy: Speaker? {
        session.currentOfferBy ?? sortedEvents.last(where: { $0.extractedOffer != nil })?.offerBy
    }

    /// The latest event that carries a cue.
    var latestCueEvent: DealEvent? {
        sortedEvents.last { ($0.cue?.isEmpty == false) }
    }

    /// Terms list for B3/S2. Uses server terms (excluding removed); falls back to accumulating `new_terms`.
    var visibleTerms: [Term] {
        if !session.terms.isEmpty {
            return session.terms.filter { !$0.removed }
        }
        var order: [String] = []
        var byKey: [String: Term] = [:]
        for e in sortedEvents {
            for nt in e.newTerms {
                let key = nt.type == "price" ? "price" : nt.label.lowercased()
                if byKey[key] == nil { order.append(key) }
                byKey[key] = Term(id: "derived_\(key)", type: nt.type, label: nt.label, amount: nt.amount,
                                  sourceEventId: e.id, uncertain: false)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    var sortedPaymentRequests: [PaymentRequest] {
        paymentRequests.enumerated().sorted { a, b in
            switch (a.element.createdAt, b.element.createdAt) {
            case let (x?, y?) where x != y: return x < y
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    var latestPaymentRequest: PaymentRequest? { sortedPaymentRequests.last }

    /// A blocked request the buyer hasn't decided on yet -> B5.
    var blockedRequestAwaitingBuyer: PaymentRequest? {
        sortedPaymentRequests.last { $0.status == .blocked && $0.decidedAt == nil }
    }

    var buyerPhase: BuyerPhase {
        if receipt != nil { return .receipt }
        if agreement != nil { return .agreement }
        return .live
    }

    var sellerPhase: SellerPhase {
        if receipt != nil { return .receipt }
        guard let agreement else { return .live }
        return agreement.isLocked ? .terminal : .agreement
    }

    var terminalState: TerminalState {
        guard let latest = latestPaymentRequest else { return .ready }
        switch latest.status {
        case .blocked: return latest.decidedAt == nil ? .waitingForBuyer(latest) : .rejected(latest)
        case .rejected: return .rejected(latest)
        case .approved: return .approved(latest)
        case .pending: return .waitingForBuyer(latest)
        case .paid, .unknown: return .ready
        }
    }

    /// The amount the terminal displays: always the agreement's total (amended if the buyer approved).
    var terminalAmount: Int? { agreement?.total }

    /// Line items that represent exactly the agreement (matches content/scripts/seller_extra_fee.json
    /// `corrected_request`): main item carries the price, other items $0, then fees.
    var agreedLineItems: [LineItem] {
        guard let agreement else { return [] }
        let mainLabel = agreement.items.first ?? (session.item.isEmpty ? "price" : session.item)
        var items = [LineItem(label: mainLabel, amount: agreement.price)]
        for extra in agreement.items.dropFirst() {
            items.append(LineItem(label: extra, amount: 0))
        }
        for fee in agreement.fees {
            items.append(LineItem(label: fee.label, amount: fee.amount))
        }
        // Safety: if price + fees != total, put the difference on the main line so the sum matches.
        let sum = items.reduce(0) { $0 + $1.amount }
        if sum != agreement.total { items[0].amount += agreement.total - sum }
        return items
    }

    /// Total cents of extras the buyer rejected (blocked charges).
    var blockedTotal: Int {
        if let r = receipt?.blockedTotal { return r }
        return sortedPaymentRequests
            .filter { $0.status == .rejected || ($0.status == .blocked && $0.decidedAt != nil) }
            .reduce(0) { total, req in
                total + max(0, req.mismatch?.difference ?? (req.amount - (agreement?.total ?? req.amount)))
            }
    }

    /// "Asked $38,000, paid $34,600, blocked $1,200"
    var receiptSummary: String {
        if let s = receipt?.summary, !s.isEmpty { return s }
        let paid = Money.format(receipt?.amount ?? agreement?.total ?? 0)
        let blocked = blockedTotal
        let blockedPart = blocked > 0 ? ", blocked \(Money.format(blocked))" : ""
        guard let askedCents = receipt?.askingPrice ?? session.askingPrice else {
            return "Paid \(paid)\(blockedPart)"
        }
        return "Asked \(Money.format(askedCents)), paid \(paid)\(blockedPart)"
    }

    /// The cue that should be on the glasses right now. A blocked charge overrides coaching cues.
    var glassesCue: GlassesCue? {
        if let blocked = blockedRequestAwaitingBuyer {
            let extra = ChargeMath.extraAmount(request: blocked, agreement: agreement)
            return GlassesCue(text: "Charge blocked. Check phone.",
                              detail: extra > 0 ? "\(Money.formatDelta(extra)) not agreed" : nil,
                              status: .red, currentOffer: agreement?.total ?? currentOffer,
                              target: session.targetPrice, isAlert: true, sourceID: "pr_\(blocked.id)")
        }
        guard let e = latestCueEvent, let cue = e.cue else { return nil }
        return GlassesCue(text: cue, detail: e.cueDetail, status: e.statusColor,
                          currentOffer: currentOffer, target: session.targetPrice, sourceID: e.id)
    }
}

enum ChargeMath {
    /// requested - agreed, preferring the backend's computed difference.
    static func extraAmount(request: PaymentRequest, agreement: Agreement?) -> Int {
        if let d = request.mismatch?.difference { return d }
        guard let agreement else { return 0 }
        return request.amount - agreement.total
    }

    /// Line items not covered by the agreement. Prefers the backend's list; otherwise a simple
    /// case-insensitive label comparison against items + fees.
    static func extraLineItems(request: PaymentRequest, agreement: Agreement?) -> [LineItem] {
        if let m = request.mismatch, !(m.unmatchedLineItems.isEmpty && m.mismatchedAmountLineItems.isEmpty) {
            return m.unmatchedLineItems + m.mismatchedAmountLineItems
        }
        guard let agreement else { return [] }
        let known = Set((agreement.items + agreement.fees.map(\.label)).map { $0.lowercased() })
        return request.lineItems.filter { !known.contains($0.label.lowercased()) && $0.amount != 0 }
    }
}

enum OfferMath {
    /// Progress from asking (0) to target (1), clamped. nil when no offer.
    static func progress(asking: Int?, target: Int?, offer: Int?) -> Double? {
        guard let offer, let asking, let target else { return nil }
        guard asking > target else { return offer <= target ? 1 : 0 }
        let p = Double(asking - offer) / Double(asking - target)
        return min(max(p, 0), 1)
    }

    static func label(asking: Int?, target: Int?, maxBudget: Int?, offer: Int?) -> OfferProgressLabel {
        guard let offer else { return .noOffer }
        if let maxBudget, offer > maxBudget, target == nil { return .overBudget }
        guard let target else { return .closing }
        if offer <= target { return .atTarget }
        if let maxBudget, offer > maxBudget {
            // Still show progress language if we're well past the midpoint, else flag the budget.
            let p = progress(asking: asking, target: target, offer: offer) ?? 0
            return p < 0.5 ? .overBudget : .closing
        }
        let p = progress(asking: asking, target: target, offer: offer) ?? 0
        if p >= 0.7 { return .near }
        if p >= 0.35 { return .closing }
        return .far
    }

    static func status(target: Int?, maxBudget: Int?, offer: Int?) -> StatusColor {
        guard let offer else { return .unknown }
        if let target, offer <= target { return .green }
        if let maxBudget, offer > maxBudget { return .red }
        if target == nil { return .unknown }
        return .yellow
    }
}

enum Fingerprint {
    /// Prefers the backend's `fingerprint_short`.
    static func short(_ agreement: Agreement?) -> String {
        if let s = agreement?.fingerprintShort, !s.isEmpty { return s }
        return short(agreement?.fingerprint)
    }

    /// `a3f9…c21`
    static func short(_ fp: String?) -> String {
        guard let fp, !fp.isEmpty else { return "—" }
        let hex = fp.hasPrefix("sha256:") ? String(fp.dropFirst(7)) : fp
        guard hex.count > 8 else { return hex }
        return "\(hex.prefix(4))…\(hex.suffix(3))"
    }
}

enum JoinCode {
    /// QR payload. Seller's scanner accepts this URL or a bare code.
    static func qrPayload(_ code: String) -> String { "deal://join?code=\(code)" }

    /// Extracts a join code from a scanned/typed string.
    static func parse(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comps = URLComponents(string: trimmed), comps.scheme != nil,
           let code = comps.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty {
            return code.uppercased()
        }
        let cleaned = trimmed.uppercased().filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? nil : cleaned
    }
}

enum TimeFormat {
    static func clock(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    static func full(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
