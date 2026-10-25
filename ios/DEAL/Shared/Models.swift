import Foundation

// Mirrors Section 6 / 12.5 of DEAL_Visa_CalHacks_Concept.md and backend/src/types.ts.
// Wire format is snake_case JSON; all money is integer cents.
// Decoders are deliberately tolerant: missing/null optional fields never fail a decode,
// unknown enum values decode to `.unknown`, ids may be strings or numbers.

// MARK: - Enums

enum Speaker: String, Codable, Sendable, CaseIterable {
    case buyer, seller

    var displayName: String { self == .buyer ? "You" : "Seller" }
}

enum StatusColor: String, Codable, Sendable {
    case green, yellow, red, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StatusColor(rawValue: raw.lowercased()) ?? .unknown
    }
}

enum SessionStatus: String, Codable, Sendable {
    case live, agreementDraft = "agreement_draft", locked, paid, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionStatus(rawValue: raw) ?? .unknown
    }
}

enum PaymentRequestStatus: String, Codable, Sendable {
    case pending, blocked, approved, rejected, paid, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaymentRequestStatus(rawValue: raw) ?? .unknown
    }
}

enum AgreementStatus: String, Codable, Sendable {
    case draft, locked, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgreementStatus(rawValue: raw) ?? .unknown
    }
}

/// Wire values for `sessions.category`.
enum DealCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case car, pawnShop = "pawn_shop", marketplace, electronics, other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .car: "Car"
        case .pawnShop: "Pawn Shop"
        case .marketplace: "Marketplace"
        case .electronics: "Electronics"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .car: "car.fill"
        case .pawnShop: "guitars.fill"
        case .marketplace: "storefront.fill"
        case .electronics: "laptopcomputer"
        case .other: "tag.fill"
        }
    }

    /// Script played by "Scripted mode" in B3 (content/scripts/<id>.json).
    var defaultScriptID: String {
        switch self {
        case .pawnShop: "pawn_guitar"
        case .marketplace: "marketplace_bike"
        default: "car_accord"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DealCategory(rawValue: raw) ?? DealCategory(rawValue: raw.replacingOccurrences(of: " ", with: "_").lowercased()) ?? .other
    }
}

enum NegotiationStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case polite, firm, aggressive
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

// MARK: - Core records

struct Term: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var type: String
    var label: String
    var amount: Int?
    var sourceEventId: String?
    var uncertain: Bool
    var corrected: Bool
    var removed: Bool

    init(id: String, type: String, label: String, amount: Int? = nil, sourceEventId: String? = nil,
         uncertain: Bool = false, corrected: Bool = false, removed: Bool = false) {
        self.id = id; self.type = type; self.label = label; self.amount = amount
        self.sourceEventId = sourceEventId; self.uncertain = uncertain
        self.corrected = corrected; self.removed = removed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLossyString(forKey: .id)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "term"
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        amount = try c.decodeLossyIntIfPresent(forKey: .amount)
        sourceEventId = try c.decodeLossyStringIfPresent(forKey: .sourceEventId)
        uncertain = try c.decodeIfPresent(Bool.self, forKey: .uncertain) ?? false
        corrected = try c.decodeIfPresent(Bool.self, forKey: .corrected) ?? false
        removed = try c.decodeIfPresent(Bool.self, forKey: .removed) ?? false
    }
}

struct NewTerm: Codable, Sendable, Hashable {
    var type: String
    var label: String
    var amount: Int?

    init(type: String, label: String, amount: Int?) {
        self.type = type; self.label = label; self.amount = amount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "term"
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        amount = try c.decodeLossyIntIfPresent(forKey: .amount)
    }
}

struct Session: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var category: DealCategory
    var item: String
    var askingPrice: Int
    var targetPrice: Int
    var maxBudget: Int
    var style: String
    var status: SessionStatus
    var joinCode: String
    var currentOffer: Int?
    var currentOfferBy: Speaker?
    var terms: [Term]
    var createdAt: Date?
    var updatedAt: Date?
    /// `GET /sessions` (history) extras; nil elsewhere.
    var finalPrice: Int?
    var paidAt: Date?
    var blockedTotal: Int?
    var savings: Int?
    /// Imported Marketplace listing (`POST /sessions` `listing`), echoed back by the backend.
    var listing: Listing?
    /// `POST /sessions/:id/condition-check` results, oldest first.
    var conditionChecks: [ConditionCheckResult]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLossyString(forKey: .id)
        category = try c.decodeIfPresent(DealCategory.self, forKey: .category) ?? .other
        item = try c.decodeIfPresent(String.self, forKey: .item) ?? ""
        askingPrice = try c.decodeLossyIntIfPresent(forKey: .askingPrice) ?? 0
        targetPrice = try c.decodeLossyIntIfPresent(forKey: .targetPrice) ?? 0
        maxBudget = try c.decodeLossyIntIfPresent(forKey: .maxBudget) ?? 0
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? NegotiationStyle.firm.rawValue
        status = try c.decodeIfPresent(SessionStatus.self, forKey: .status) ?? .live
        joinCode = try c.decodeLossyStringIfPresent(forKey: .joinCode) ?? ""
        currentOffer = try c.decodeLossyIntIfPresent(forKey: .currentOffer)
        currentOfferBy = try? c.decodeIfPresent(Speaker.self, forKey: .currentOfferBy)
        terms = (try? c.decodeIfPresent([Term].self, forKey: .terms)) ?? []
        createdAt = c.decodeFlexibleDateIfPresent(forKey: .createdAt)
        updatedAt = c.decodeFlexibleDateIfPresent(forKey: .updatedAt)
        finalPrice = try c.decodeLossyIntIfPresent(forKey: .finalPrice)
        paidAt = c.decodeFlexibleDateIfPresent(forKey: .paidAt)
        blockedTotal = try c.decodeLossyIntIfPresent(forKey: .blockedTotal)
        savings = try c.decodeLossyIntIfPresent(forKey: .savings)
        listing = try? c.decodeIfPresent(Listing.self, forKey: .listing)
        conditionChecks = (try? c.decodeIfPresent([ConditionCheckResult].self, forKey: .conditionChecks)) ?? []
    }
}

struct DealEvent: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var sessionId: String
    var seq: Int?
    var speaker: Speaker
    var text: String
    var timestamp: Date?
    var extractedOffer: Int?
    var offerBy: Speaker?
    var newTerms: [NewTerm]
    var tactic: String?
    var cue: String?
    /// Optional second cue line (e.g. "$489/mo × 72 = $35,208"). Present in content scripts;
    /// tolerated if the backend omits it.
    var cueDetail: String?
    var statusColor: StatusColor
    var scriptLineId: String?
    /// `speech` (a transcript line) or `condition_check` (a cue from B3 "Check condition").
    var kind: String?

    var isConditionCheck: Bool { kind == "condition_check" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLossyString(forKey: .id)
        sessionId = try c.decodeLossyStringIfPresent(forKey: .sessionId) ?? ""
        seq = try c.decodeLossyIntIfPresent(forKey: .seq)
        speaker = (try? c.decodeIfPresent(Speaker.self, forKey: .speaker)) ?? .seller
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        timestamp = c.decodeFlexibleDateIfPresent(forKey: .timestamp)
        extractedOffer = try c.decodeLossyIntIfPresent(forKey: .extractedOffer)
        offerBy = try? c.decodeIfPresent(Speaker.self, forKey: .offerBy)
        newTerms = (try? c.decodeIfPresent([NewTerm].self, forKey: .newTerms)) ?? []
        tactic = try c.decodeIfPresent(String.self, forKey: .tactic)
        cue = try c.decodeIfPresent(String.self, forKey: .cue)
        cueDetail = try c.decodeIfPresent(String.self, forKey: .cueDetail)
        statusColor = (try? c.decodeIfPresent(StatusColor.self, forKey: .statusColor)) ?? .unknown
        scriptLineId = try c.decodeLossyStringIfPresent(forKey: .scriptLineId)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
    }
}

struct Fee: Codable, Sendable, Hashable {
    var label: String
    var amount: Int
    var note: String?

    init(label: String, amount: Int, note: String? = nil) {
        self.label = label; self.amount = amount; self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        amount = try c.decodeLossyIntIfPresent(forKey: .amount) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

struct Amendment: Codable, Sendable, Hashable {
    var at: Date?
    var paymentRequestId: String?
    var addedFees: [Fee]
    var previousTotal: Int?
    var newTotal: Int?
    var previousFingerprint: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = c.decodeFlexibleDateIfPresent(forKey: .at)
        paymentRequestId = try c.decodeLossyStringIfPresent(forKey: .paymentRequestId)
        addedFees = (try? c.decodeIfPresent([Fee].self, forKey: .addedFees)) ?? []
        previousTotal = try c.decodeLossyIntIfPresent(forKey: .previousTotal)
        newTotal = try c.decodeLossyIntIfPresent(forKey: .newTotal)
        previousFingerprint = try c.decodeIfPresent(String.self, forKey: .previousFingerprint)
    }
}

struct Agreement: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var sessionId: String
    var price: Int
    var items: [String]
    var fees: [Fee]
    var total: Int
    var sourceEventIds: [String]
    var openQuestions: [String]
    var status: AgreementStatus
    var buyerConfirmedAt: Date?
    var sellerConfirmedAt: Date?
    var fingerprint: String?
    var version: Int
    var amendments: [Amendment]
    var createdAt: Date?
    var updatedAt: Date?
    /// Display-only decorations added by the backend (`decorateAgreement`), not stored.
    var fingerprintShort: String?
    var fingerprintValid: Bool?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLossyString(forKey: .id)
        sessionId = try c.decodeLossyStringIfPresent(forKey: .sessionId) ?? ""
        price = try c.decodeLossyIntIfPresent(forKey: .price) ?? 0
        items = (try? c.decodeIfPresent([String].self, forKey: .items)) ?? []
        fees = (try? c.decodeIfPresent([Fee].self, forKey: .fees)) ?? []
        total = try c.decodeLossyIntIfPresent(forKey: .total) ?? price
        sourceEventIds = (try? c.decodeIfPresent([String].self, forKey: .sourceEventIds)) ?? []
        openQuestions = (try? c.decodeIfPresent([String].self, forKey: .openQuestions)) ?? []
        status = (try? c.decodeIfPresent(AgreementStatus.self, forKey: .status)) ?? .draft
        buyerConfirmedAt = c.decodeFlexibleDateIfPresent(forKey: .buyerConfirmedAt)
        sellerConfirmedAt = c.decodeFlexibleDateIfPresent(forKey: .sellerConfirmedAt)
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint)
        version = try c.decodeLossyIntIfPresent(forKey: .version) ?? 1
        amendments = (try? c.decodeIfPresent([Amendment].self, forKey: .amendments)) ?? []
        createdAt = c.decodeFlexibleDateIfPresent(forKey: .createdAt)
        updatedAt = c.decodeFlexibleDateIfPresent(forKey: .updatedAt)
        fingerprintShort = try c.decodeIfPresent(String.self, forKey: .fingerprintShort)
        fingerprintValid = try c.decodeIfPresent(Bool.self, forKey: .fingerprintValid)
    }

    var buyerConfirmed: Bool { buyerConfirmedAt != nil }
    var sellerConfirmed: Bool { sellerConfirmedAt != nil }
    var isLocked: Bool { status == .locked || (buyerConfirmed && sellerConfirmed && fingerprint != nil) }

    func isConfirmed(by role: Speaker) -> Bool {
        role == .buyer ? buyerConfirmed : sellerConfirmed
    }
}

struct LineItem: Codable, Sendable, Hashable {
    var label: String
    var amount: Int

    init(label: String, amount: Int) {
        self.label = label; self.amount = amount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        amount = try c.decodeLossyIntIfPresent(forKey: .amount) ?? 0
    }
}

struct MismatchDetails: Codable, Sendable, Hashable {
    var ok: Bool
    var reasons: [String]
    var fingerprintValid: Bool
    var agreedTotal: Int?
    var requestedTotal: Int?
    var difference: Int?
    var unmatchedLineItems: [LineItem]
    /// Labels that exist in the agreement but with a different amount.
    var mismatchedAmountLineItems: [LineItem]
    var sourceEventId: String?
    var sourceEventText: String?
    var sourceEventTimestamp: Date?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        reasons = (try? c.decodeIfPresent([String].self, forKey: .reasons)) ?? []
        fingerprintValid = try c.decodeIfPresent(Bool.self, forKey: .fingerprintValid) ?? true
        agreedTotal = try c.decodeLossyIntIfPresent(forKey: .agreedTotal)
        requestedTotal = try c.decodeLossyIntIfPresent(forKey: .requestedTotal)
        difference = try c.decodeLossyIntIfPresent(forKey: .difference)
        unmatchedLineItems = (try? c.decodeIfPresent([LineItem].self, forKey: .unmatchedLineItems)) ?? []
        mismatchedAmountLineItems = (try? c.decodeIfPresent([LineItem].self, forKey: .mismatchedAmountLineItems)) ?? []
        sourceEventId = try c.decodeLossyStringIfPresent(forKey: .sourceEventId)
        sourceEventText = try c.decodeIfPresent(String.self, forKey: .sourceEventText)
        sourceEventTimestamp = c.decodeFlexibleDateIfPresent(forKey: .sourceEventTimestamp)
    }
}

struct PaymentRequest: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var sessionId: String
    var agreementId: String?
    var amount: Int
    var lineItems: [LineItem]
    var status: PaymentRequestStatus
    var mismatchExplanation: String?
    var mismatch: MismatchDetails?
    var decidedAt: Date?
    var createdAt: Date?
    var updatedAt: Date?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLossyString(forKey: .id)
        sessionId = try c.decodeLossyStringIfPresent(forKey: .sessionId) ?? ""
        agreementId = try c.decodeLossyStringIfPresent(forKey: .agreementId)
        lineItems = (try? c.decodeIfPresent([LineItem].self, forKey: .lineItems)) ?? []
        amount = try c.decodeLossyIntIfPresent(forKey: .amount) ?? lineItems.reduce(0) { $0 + $1.amount }
        status = (try? c.decodeIfPresent(PaymentRequestStatus.self, forKey: .status)) ?? .unknown
        mismatchExplanation = try c.decodeIfPresent(String.self, forKey: .mismatchExplanation)
        mismatch = try? c.decodeIfPresent(MismatchDetails.self, forKey: .mismatch)
        decidedAt = c.decodeFlexibleDateIfPresent(forKey: .decidedAt)
        createdAt = c.decodeFlexibleDateIfPresent(forKey: .createdAt)
        updatedAt = c.decodeFlexibleDateIfPresent(forKey: .updatedAt)
    }
}

struct Receipt: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var sessionId: String
    var paymentRequestId: String?
    var stripePaymentId: String
    var amount: Int
    var currency: String
    var status: String
    var agreementFingerprint: String
    var merchant: String?
    var askingPrice: Int?
    var blockedTotal: Int?
    var summary: String?
    var mock: Bool
    var createdAt: Date?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLossyString(forKey: .id)
        sessionId = try c.decodeLossyStringIfPresent(forKey: .sessionId) ?? ""
        paymentRequestId = try c.decodeLossyStringIfPresent(forKey: .paymentRequestId)
        stripePaymentId = try c.decodeIfPresent(String.self, forKey: .stripePaymentId) ?? ""
        amount = try c.decodeLossyIntIfPresent(forKey: .amount) ?? 0
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "usd"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "succeeded"
        agreementFingerprint = try c.decodeIfPresent(String.self, forKey: .agreementFingerprint) ?? ""
        merchant = try c.decodeIfPresent(String.self, forKey: .merchant)
        askingPrice = try c.decodeLossyIntIfPresent(forKey: .askingPrice)
        blockedTotal = try c.decodeLossyIntIfPresent(forKey: .blockedTotal)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        mock = try c.decodeIfPresent(Bool.self, forKey: .mock) ?? false
        createdAt = c.decodeFlexibleDateIfPresent(forKey: .createdAt)
    }
}

/// `GET /sessions/:id` -> `{session, events, agreement, payment_requests, receipt}`.
struct SessionState: Codable, Sendable, Hashable {
    var session: Session
    var events: [DealEvent]
    var agreement: Agreement?
    var paymentRequests: [PaymentRequest]
    var receipt: Receipt?
    /// Scripted-mode progress (backend extra; nil when no script has been played).
    var script: ScriptRun?
    /// Tolerated if the backend puts the listing at the top level instead of `session.listing`.
    var topLevelListing: Listing?
    /// Tolerated if the backend persists condition checks (`condition_checks` / `discrepancies`).
    var serverDiscrepancies: [Discrepancy]
    /// Live market research agents (backend `research`, see Research.swift).
    var research: ResearchState?
    /// Suggested things to say next (backend `suggestions`).
    var suggestions: PhraseSuggestions?

    init(session: Session, events: [DealEvent] = [], agreement: Agreement? = nil,
         paymentRequests: [PaymentRequest] = [], receipt: Receipt? = nil, script: ScriptRun? = nil) {
        self.session = session; self.events = events; self.agreement = agreement
        self.paymentRequests = paymentRequests; self.receipt = receipt; self.script = script
        self.topLevelListing = nil; self.serverDiscrepancies = []
        self.research = nil; self.suggestions = nil
    }

    enum CodingKeys: String, CodingKey {
        case session, events, agreement, paymentRequests, receipt, script, research, suggestions
        case topLevelListing = "listing"
        case serverDiscrepancies = "discrepancies"
        case conditionChecks
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(session, forKey: .session)
        try c.encode(events, forKey: .events)
        try c.encodeIfPresent(agreement, forKey: .agreement)
        try c.encode(paymentRequests, forKey: .paymentRequests)
        try c.encodeIfPresent(receipt, forKey: .receipt)
        try c.encodeIfPresent(script, forKey: .script)
        try c.encodeIfPresent(research, forKey: .research)
        try c.encodeIfPresent(suggestions, forKey: .suggestions)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decode(Session.self, forKey: .session)
        events = try c.decodeIfPresent([DealEvent].self, forKey: .events) ?? []
        agreement = try c.decodeIfPresent(Agreement.self, forKey: .agreement)
        paymentRequests = try c.decodeIfPresent([PaymentRequest].self, forKey: .paymentRequests) ?? []
        receipt = try c.decodeIfPresent(Receipt.self, forKey: .receipt)
        script = try? c.decodeIfPresent(ScriptRun.self, forKey: .script)
        topLevelListing = try? c.decodeIfPresent(Listing.self, forKey: .topLevelListing)
        serverDiscrepancies = Self.decodeDiscrepancies(c)
        research = try? c.decodeIfPresent(ResearchState.self, forKey: .research)
        suggestions = try? c.decodeIfPresent(PhraseSuggestions.self, forKey: .suggestions)
    }

    /// `discrepancies: [...]`, or `condition_checks: [{discrepancies: [...]}]` / `[Discrepancy]`.
    private static func decodeDiscrepancies(_ c: KeyedDecodingContainer<CodingKeys>) -> [Discrepancy] {
        if let list = try? c.decodeIfPresent([Discrepancy].self, forKey: .serverDiscrepancies) { return list }
        if let checks = try? c.decodeIfPresent([ConditionCheckResult].self, forKey: .conditionChecks) {
            let nested = checks.flatMap(\.discrepancies)
            if !nested.isEmpty { return nested }
        }
        if let flat = try? c.decodeIfPresent([Discrepancy].self, forKey: .conditionChecks) { return flat }
        return []
    }
}

/// `SessionState.script` — `{script_id, total, played, done, error, started_at}`.
struct ScriptRun: Codable, Sendable, Hashable {
    var scriptId: String
    var total: Int
    var played: Int
    var done: Bool
    var error: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scriptId = try c.decodeIfPresent(String.self, forKey: .scriptId) ?? ""
        total = try c.decodeLossyIntIfPresent(forKey: .total) ?? 0
        played = try c.decodeLossyIntIfPresent(forKey: .played) ?? 0
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    var isPlaying: Bool { !done && error == nil }
}

/// One listing on the B2 "Comparable prices" card (`GET /comparables/:category`).
struct Comparable: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var title: String
    var price: Int
    var source: String?
    var detail: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        title = c.firstString(["title", "name", "item", "label"]) ?? "Listing"
        // Keys are camelCase here because the decoder uses .convertFromSnakeCase.
        price = c.firstInt(["price", "amount", "priceCents", "listedPrice", "askingPrice"]) ?? 0
        source = c.firstString(["source", "seller", "venue", "location"])
        detail = c.firstString(["detail", "details", "condition", "mileage", "note", "notes", "description"])
        id = c.firstString(["id"]) ?? "\(title)-\(price)"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(title, forKey: AnyKey("title"))
        try c.encode(price, forKey: AnyKey("price"))
        try c.encodeIfPresent(source, forKey: AnyKey("source"))
        try c.encodeIfPresent(detail, forKey: AnyKey("detail"))
    }
}

// MARK: - Request bodies

struct CreateSessionBody: Encodable, Sendable {
    var category: String
    var item: String
    var askingPrice: Int
    var targetPrice: Int
    var maxBudget: Int
    var style: String
    /// Imported Marketplace listing (optional).
    var listing: Listing? = nil
}

struct JoinSessionBody: Encodable, Sendable { var joinCode: String }

struct PostEventBody: Encodable, Sendable {
    var speaker: Speaker
    var text: String
}

struct PlayScriptBody: Encodable, Sendable {
    var scriptId: String
    var intervalMs: Int?
}

struct PlayScriptResponse: Decodable, Sendable {
    var started: Bool
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        started = (try? c.decode(Bool.self, forKey: AnyKey("started"))) ?? true
    }
}

/// `PATCH /sessions/:id/terms` -> `{term_id, correction}`.
struct TermCorrection: Encodable, Sendable, Hashable {
    var label: String?
    var amount: Int?
    var type: String? = nil
    var removed: Bool?
}

struct FixTermBody: Encodable, Sendable {
    var termId: String
    var correction: TermCorrection
}

struct ConfirmBody: Encodable, Sendable { var role: Speaker }

struct PaymentRequestBody: Encodable, Sendable { var lineItems: [LineItem] }

enum PaymentDecision: String, Encodable, Sendable { case approve, reject }
struct DecisionBody: Encodable, Sendable { var decision: PaymentDecision }

// MARK: - Decoding helpers

struct AnyKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?
    init(_ s: String) { stringValue = s; intValue = nil }
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

extension KeyedDecodingContainer where Key == AnyKey {
    func firstString(_ keys: [String]) -> String? {
        for k in keys {
            let key = AnyKey(k)
            if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
            if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        }
        return nil
    }

    func firstInt(_ keys: [String]) -> Int? {
        for k in keys {
            if let i = try? decodeLossyIntIfPresent(forKey: AnyKey(k)) { return i }
        }
        return nil
    }
}

extension KeyedDecodingContainer {
    /// String id that may arrive as a JSON number.
    func decodeLossyString(forKey key: Key) throws -> String {
        if let s = try decodeLossyStringIfPresent(forKey: key) { return s }
        throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "missing \(key.stringValue)"))
    }

    func decodeLossyStringIfPresent(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let s = try? decode(String.self, forKey: key) { return s }
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        return nil
    }

    /// Integer cents that may arrive as Int, a whole Double (3460000.0), or a numeric string.
    func decodeLossyIntIfPresent(forKey key: Key) throws -> Int? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let i = try? decode(Int.self, forKey: key) { return i }
        if let d = try? decode(Double.self, forKey: key), d.isFinite { return Int(d.rounded()) }
        if let s = try? decode(String.self, forKey: key), let i = Int(s) { return i }
        return nil
    }

    /// ISO 8601 (with or without fractional seconds) or epoch seconds/milliseconds.
    func decodeFlexibleDateIfPresent(forKey key: Key) -> Date? {
        guard contains(key), (try? decodeNil(forKey: key)) == false else { return nil }
        if let s = try? decode(String.self, forKey: key) { return FlexibleDate.parse(s) }
        if let d = try? decode(Double.self, forKey: key) { return FlexibleDate.fromEpoch(d) }
        return nil
    }
}

enum FlexibleDate {
    static func parse(_ s: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }
        if let n = Double(s) { return fromEpoch(n) }
        return nil
    }

    static func fromEpoch(_ n: Double) -> Date {
        n > 1_000_000_000_000 ? Date(timeIntervalSince1970: n / 1000) : Date(timeIntervalSince1970: n)
    }
}
