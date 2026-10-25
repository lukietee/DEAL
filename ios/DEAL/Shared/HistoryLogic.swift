import Foundation

// Pure derivations for B1 Home and B7 Purchase History / Deal Detail. No UI, no I/O.

extension Session {
    /// Paid sessions are purchases (B7). `GET /sessions` adds `paid_at` / `final_price`.
    var isPurchase: Bool { status == .paid || paidAt != nil }

    /// Ended with `POST /sessions/:id/end` (a paid session can be ended too).
    var isEnded: Bool { status == .ended || endedAt != nil }

    /// Still negotiating / waiting to be charged: something to resume on B1.
    var isOpen: Bool { !isPurchase && !isEnded && status != .unknown }

    /// Savings vs the asking price. Prefers the backend's `savings`.
    var savingsVsAsking: Int? {
        if let savings { return savings }
        guard let finalPrice, let askingPrice else { return nil }
        return askingPrice - finalPrice
    }

    /// When the deal happened, for sorting and the history row.
    var dealDate: Date? { paidAt ?? endedAt ?? updatedAt ?? createdAt }

    /// The outcome chip on history rows.
    var historyOutcome: HistoryOutcome {
        if isPurchase { return .paid(finalPrice ?? summary?.finalPrice) }
        switch summary?.outcome {
        case .deal: return .deal(summary?.finalPrice ?? finalPrice)
        case .noDeal: return .noDeal
        default: break
        }
        return isEnded ? .ended : .live
    }
}

/// What happened in a conversation, as shown on B1 Recent / B7 rows.
enum HistoryOutcome: Equatable, Sendable {
    /// Paid through DEAL.
    case paid(Int?)
    /// The summary says they agreed (paid some other way, or not yet).
    case deal(Int?)
    case noDeal
    /// Still running: the row resumes it.
    case live
    /// Ended without a clear outcome.
    case ended

    /// "Paid · $520", "Deal · $200", "No deal", "Live", "Ended".
    var label: String {
        switch self {
        case .paid(let p): p.map { "Paid · \(Money.format($0))" } ?? "Paid"
        case .deal(let p): p.map { "Deal · \(Money.format($0))" } ?? "Deal"
        case .noDeal: "No deal"
        case .live: "Live"
        case .ended: "Ended"
        }
    }

    var isLive: Bool { self == .live }
}

struct PurchaseTotals: Equatable, Sendable {
    var count: Int
    var spent: Int
    var blocked: Int
    var saved: Int
}

enum PurchaseHistory {
    /// Paid sessions, newest first.
    static func purchases(_ sessions: [Session]) -> [Session] {
        newestFirst(sessions.filter(\.isPurchase))
    }

    /// Every conversation (paid, ended, live), newest first: B1 Recent and B7.
    /// Listening sessions where no product was ever detected (started, then abandoned) are left out;
    /// the active one is still reachable from B1's Active session card.
    static func conversations(_ sessions: [Session]) -> [Session] {
        newestFirst(sessions.filter { !($0.auto && !$0.detected) })
    }

    private static func newestFirst(_ sessions: [Session]) -> [Session] {
        sessions.sorted { ($0.dealDate ?? .distantPast) > ($1.dealDate ?? .distantPast) }
    }

    static func totals(_ sessions: [Session]) -> PurchaseTotals {
        let paid = purchases(sessions)
        return PurchaseTotals(
            count: paid.count,
            spent: paid.reduce(0) { $0 + ($1.finalPrice ?? 0) },
            blocked: paid.reduce(0) { $0 + max(0, $1.blockedTotal ?? 0) },
            saved: paid.reduce(0) { $0 + max(0, $1.savingsVsAsking ?? 0) })
    }

    /// The most recent unfinished session on the backend (e.g. after an app relaunch), if it was
    /// touched within `within` seconds.
    static func resumable(_ sessions: [Session], now: Date = Date(), within: TimeInterval = 6 * 3600) -> Session? {
        sessions.filter(\.isOpen)
            .filter { s in (s.updatedAt ?? s.createdAt).map { now.timeIntervalSince($0) <= within } ?? false }
            .max { ($0.updatedAt ?? $0.createdAt ?? .distantPast) < ($1.updatedAt ?? $1.createdAt ?? .distantPast) }
    }
}

/// One step of the Deal Detail offer timeline.
struct OfferPoint: Equatable, Sendable, Identifiable {
    var id: String
    var amount: Int
    var by: Speaker
    var timestamp: Date?
    var text: String
}

/// One coaching cue that was shown on the glasses during the negotiation.
struct KeyCue: Equatable, Sendable, Identifiable {
    var id: String
    var text: String
    var detail: String?
    var status: StatusColor
    var tactic: String?
    var timestamp: Date?
}

extension SessionState {
    /// Every offer in order; repeats of the same amount by the same side are dropped.
    var offerTimeline: [OfferPoint] {
        var points: [OfferPoint] = []
        for e in sortedEvents {
            guard let amount = e.extractedOffer else { continue }
            let by = e.offerBy ?? e.speaker
            if let last = points.last, last.amount == amount, last.by == by { continue }
            points.append(OfferPoint(id: e.id, amount: amount, by: by, timestamp: e.timestamp, text: e.text))
        }
        return points
    }

    /// Cues in order; consecutive repeats of the same cue are dropped.
    var keyCues: [KeyCue] {
        var cues: [KeyCue] = []
        for e in sortedEvents {
            guard let text = e.cue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            if cues.last?.text == text { continue }
            cues.append(KeyCue(id: e.id, text: text, detail: e.cueDetail, status: e.statusColor,
                               tactic: e.tactic, timestamp: e.timestamp))
        }
        return cues
    }

    /// Charges the buyer refused (blocked, then rejected).
    var refusedCharges: [PaymentRequest] {
        sortedPaymentRequests.filter { $0.status == .rejected || ($0.status == .blocked && $0.decidedAt != nil) }
    }
}

extension String {
    /// `monthly_payment_framing` -> `Monthly payment framing`.
    var humanizedIdentifier: String {
        replacingOccurrences(of: "_", with: " ").capitalizedFirst
    }
}
