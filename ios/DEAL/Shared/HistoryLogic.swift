import Foundation

// Pure derivations for B1 Home and B7 Purchase History / Deal Detail. No UI, no I/O.

extension Session {
    /// Paid sessions are purchases (B7). `GET /sessions` adds `paid_at` / `final_price`.
    var isPurchase: Bool { status == .paid || paidAt != nil }

    /// Still negotiating / waiting to be charged: something to resume on B1.
    var isOpen: Bool { !isPurchase && status != .unknown }

    /// Savings vs the asking price. Prefers the backend's `savings`.
    var savingsVsAsking: Int? {
        if let savings { return savings }
        guard let finalPrice else { return nil }
        return askingPrice - finalPrice
    }

    /// When the deal happened, for sorting and the history row.
    var dealDate: Date? { paidAt ?? updatedAt ?? createdAt }
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
        sessions.filter(\.isPurchase).sorted { ($0.dealDate ?? .distantPast) > ($1.dealDate ?? .distantPast) }
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
