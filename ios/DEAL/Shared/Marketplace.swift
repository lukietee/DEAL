import Foundation

// Facebook Marketplace meetups (the flagship demo): an imported listing, condition checks
// against what the listing claims, and request bodies for the two marketplace endpoints.
// Same rules as Models.swift: snake_case on the wire, integer cents, tolerant decoding.

/// `POST /listings/parse` -> `Listing`; also `POST /sessions` `listing` and `session.listing`.
/// `{title, asking_price, category, condition_claims[], description, location?, seller_name?, source, url?}`
struct Listing: Codable, Sendable, Hashable {
    var title: String
    var askingPrice: Int
    var category: String
    var conditionClaims: [String]
    var description: String
    var location: String?
    var sellerName: String?
    /// `facebook_marketplace` | `other`
    var source: String
    var url: String?

    init(title: String, askingPrice: Int, category: String = DealCategory.marketplace.rawValue,
         conditionClaims: [String], description: String = "", location: String? = nil,
         sellerName: String? = nil, source: String = "facebook_marketplace", url: String? = nil) {
        self.title = title; self.askingPrice = askingPrice; self.category = category
        self.conditionClaims = conditionClaims; self.description = description; self.location = location
        self.sellerName = sellerName; self.source = source; self.url = url
    }

    init(from decoder: Decoder) throws {
        // Keys are camelCase here because the decoder uses .convertFromSnakeCase.
        let c = try decoder.container(keyedBy: AnyKey.self)
        title = c.firstString(["title", "item", "name"]) ?? "Listing"
        askingPrice = c.firstInt(["askingPrice", "price", "listedPrice", "priceCents"]) ?? 0
        category = c.firstString(["category"]) ?? DealCategory.marketplace.rawValue
        conditionClaims = Self.claims(c, ["conditionClaims", "claims", "condition"])
        description = c.firstString(["description", "details", "body"]) ?? ""
        location = c.firstString(["location", "city"])
        sellerName = c.firstString(["sellerName", "seller"])
        source = c.firstString(["source"]) ?? "other"
        url = c.firstString(["url", "link"])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(title, forKey: AnyKey("title"))
        try c.encode(askingPrice, forKey: AnyKey("askingPrice"))
        try c.encode(category, forKey: AnyKey("category"))
        try c.encode(conditionClaims, forKey: AnyKey("conditionClaims"))
        try c.encode(description, forKey: AnyKey("description"))
        try c.encodeIfPresent(location, forKey: AnyKey("location"))
        try c.encodeIfPresent(sellerName, forKey: AnyKey("sellerName"))
        try c.encode(source, forKey: AnyKey("source"))
        try c.encodeIfPresent(url, forKey: AnyKey("url"))
    }

    /// `["New tires", ...]`, `[{claim|text|label}]`, or a single string.
    private static func claims(_ c: KeyedDecodingContainer<AnyKey>, _ keys: [String]) -> [String] {
        struct LossyClaim: Decodable {
            var text: String?
            init(from decoder: Decoder) throws {
                if let s = try? decoder.singleValueContainer().decode(String.self) { text = s; return }
                let c = try decoder.container(keyedBy: AnyKey.self)
                text = c.firstString(["claim", "text", "label", "value"])
            }
        }
        for k in keys {
            if let list = try? c.decodeIfPresent([LossyClaim].self, forKey: AnyKey(k)) {
                return list.compactMap(\.text).filter { !$0.isEmpty }
            }
            if let one = try? c.decodeIfPresent(String.self, forKey: AnyKey(k)), !one.isEmpty { return [one] }
        }
        return []
    }

    var isFacebookMarketplace: Bool { source == "facebook_marketplace" }
    var sourceDisplayName: String { isFacebookMarketplace ? "Facebook Marketplace" : "Listing" }
}

/// One condition mismatch: `{claim, observed, suggested_discount, cue}`.
struct Discrepancy: Codable, Sendable, Hashable, Identifiable {
    var claim: String
    var observed: String
    var suggestedDiscount: Int?
    var cue: String?

    var id: String { "\(claim)|\(observed)" }

    init(claim: String, observed: String, suggestedDiscount: Int?, cue: String?) {
        self.claim = claim; self.observed = observed; self.suggestedDiscount = suggestedDiscount; self.cue = cue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        claim = c.firstString(["claim", "listingClaim", "listed"]) ?? ""
        observed = c.firstString(["observed", "seen", "observation", "finding"]) ?? ""
        suggestedDiscount = c.firstInt(["suggestedDiscount", "discount", "suggestedDiscountCents", "amount"])
        cue = c.firstString(["cue", "text"])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(claim, forKey: AnyKey("claim"))
        try c.encode(observed, forKey: AnyKey("observed"))
        try c.encodeIfPresent(suggestedDiscount, forKey: AnyKey("suggestedDiscount"))
        try c.encodeIfPresent(cue, forKey: AnyKey("cue"))
    }
}

/// `POST /sessions/:id/condition-check` -> `{discrepancies: [...], event}`.
struct ConditionCheckResult: Codable, Sendable, Hashable {
    var discrepancies: [Discrepancy]
    /// The cue event the backend inserted (reaches the glasses through the normal cue path).
    var event: DealEvent?

    init(discrepancies: [Discrepancy], event: DealEvent? = nil) {
        self.discrepancies = discrepancies; self.event = event
    }

    init(from decoder: Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode([Discrepancy].self) {
            discrepancies = list; event = nil; return
        }
        let c = try decoder.container(keyedBy: AnyKey.self)
        discrepancies = (try? c.decodeIfPresent([Discrepancy].self, forKey: AnyKey("discrepancies"))) ?? []
        event = try? c.decodeIfPresent(DealEvent.self, forKey: AnyKey("event"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(discrepancies, forKey: AnyKey("discrepancies"))
        try c.encodeIfPresent(event, forKey: AnyKey("event"))
    }
}

struct ParseListingBody: Encodable, Sendable {
    var url: String?
    var text: String?
    var imageBase64: String?
}

struct ConditionCheckBody: Encodable, Sendable {
    var observation: String?
    var imageBase64: String?
}

enum MarketplaceDemo {
    /// What "Use demo values" imports (the mock backend returns the road bike for any input).
    static let listingURL = "https://www.facebook.com/marketplace/item/1083266512345678/"

    /// Typed observation for the Simulator (no camera). Matches the mock's "worn tires" finding.
    static let sampleObservation = "Tires are worn, tread is almost flat, small scratch on the top tube"

    /// Offline stand-in if `/listings/parse` isn't reachable, so the demo still runs.
    static let offlineBike = Listing(
        title: "56cm Aluminum Road Bike, Shimano 105",
        askingPrice: 65_000,
        conditionClaims: ["like new", "new tires last month", "no scratches", "shifts perfectly"],
        description: "Selling my road bike, barely ridden. 56cm aluminum frame, full Shimano 105 groupset, new tires last month. Like new, no scratches, shifts perfectly. Pickup only.",
        location: "Berkeley, CA",
        sellerName: "Jordan M.",
        source: "facebook_marketplace",
        url: listingURL)

    /// B2 defaults for an imported price: target 80% of asking, max ~88.5%, rounded to $5.
    /// $650 -> target $520, max $575.
    static func defaults(asking: Int) -> (target: Int, max: Int) {
        func round5(_ cents: Double) -> Int { Int((cents / 500).rounded()) * 500 }
        let target = round5(Double(asking) * 0.80)
        let max = Swift.max(target, round5(Double(asking) * 0.885))
        return (target, max)
    }
}

extension SessionState {
    /// `session.listing`, or a top-level `listing` if the backend shapes it that way.
    var listing: Listing? { session.listing ?? topLevelListing }

    /// Mismatches the backend stored (`session.condition_checks[].discrepancies`, or top-level
    /// fallbacks), oldest first.
    var storedDiscrepancies: [Discrepancy] {
        session.conditionChecks.flatMap(\.discrepancies) + serverDiscrepancies
    }

    /// Marketplace meetup: verified-handoff receipts, condition checks, listing claims.
    var isMarketplace: Bool { session.category == .marketplace || listing != nil }
}
