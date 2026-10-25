import SwiftUI

// Marketplace pieces shared by B2 (listing card), B3 (claims strip, discrepancy card) and
// B6 / S5 (verified handoff).

/// B2: compact card for an imported listing (title, asking price, source, condition claims).
struct ListingCard: View {
    var listing: Listing
    var note: String? = nil
    var onRemove: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: listing.isFacebookMarketplace ? "storefront.fill" : "doc.text")
                    .foregroundStyle(Theme.accent)
                Text(listing.sourceDisplayName.uppercased())
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let onRemove {
                    Button(action: onRemove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove listing")
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(listing.title).font(.headline).lineLimit(2)
                Spacer(minLength: 8)
                Text(Money.format(listing.askingPrice))
                    .font(.title3.weight(.bold).monospacedDigit())
            }
            let meta = [listing.location, listing.sellerName].compactMap { $0 }.filter { !$0.isEmpty }
            if !meta.isEmpty {
                Text(meta.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            if !listing.conditionClaims.isEmpty {
                Text("Seller claims").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ClaimChips(claims: listing.conditionClaims, wrap: true)
            }
            if let note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("listingCard")
    }
}

/// The listing's condition claims as small chips. Claims contradicted by a condition check
/// turn red with a warning glyph.
struct ClaimChips: View {
    var claims: [String]
    var flagged: Set<String> = []
    /// Wrap onto several lines (B2) or a single scrolling line (B3 pinned panel).
    var wrap = false

    var body: some View {
        if wrap {
            FlowLayout(spacing: 6) { chips }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { chips }
            }
        }
    }

    private var chips: some View {
        ForEach(claims, id: \.self) { claim in
            let bad = Self.isFlagged(claim, flagged)
            HStack(spacing: 3) {
                Image(systemName: bad ? "exclamationmark.triangle.fill" : "checkmark.seal")
                Text(claim)
                    .strikethrough(bad, color: .red)
            }
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(bad ? Color.red.opacity(0.15) : Color.secondary.opacity(0.12)))
            .foregroundStyle(bad ? Color.red : Color.primary)
        }
    }

    /// Loose match: "New tires" vs a discrepancy claim of "new tires" / "Listing says new tires".
    static func isFlagged(_ claim: String, _ flagged: Set<String>) -> Bool {
        let c = claim.lowercased()
        return flagged.contains { f in
            let f = f.lowercased()
            return !f.isEmpty && (f.contains(c) || c.contains(f))
        }
    }
}

/// "Listing: new tires · Seen: worn · ask $40 off". Compact for the B3 pinned panel, full in the sheet.
struct DiscrepancyCard: View {
    var discrepancy: Discrepancy
    var compact = false
    var moreCount = 0

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(compact ? .subheadline : .title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                if !compact {
                    Text("CONDITION MISMATCH").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
                (Text("Listing: ").foregroundStyle(.secondary) + Text(discrepancy.claim).bold()
                 + Text("  ·  Seen: ").foregroundStyle(.secondary) + Text(discrepancy.observed).bold())
                    .font(compact ? .footnote : .subheadline)
                    .lineLimit(compact ? 1 : 3)
                    .minimumScaleFactor(0.8)
                if !compact, let cue = discrepancy.cue, !cue.isEmpty {
                    Text("Glasses: \u{201C}\(cue)\u{201D}").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if let discount = discrepancy.suggestedDiscount, discount > 0 {
                    Text("ask \(Money.format(discount)) off")
                        .font((compact ? Font.footnote : Font.headline).weight(.bold).monospacedDigit())
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
                if moreCount > 0 {
                    Text("+\(moreCount) more").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: compact ? 10 : Theme.cornerRadius, style: .continuous)
            .fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: compact ? 10 : Theme.cornerRadius, style: .continuous)
            .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("discrepancyCard")
    }
}

/// B6 / S5 for Marketplace meetups: the anti-scam moment. The payment is confirmed by the
/// backend on BOTH phones, so neither side has to trust a "payment sent" screenshot. A live
/// "verified Ns ago" clock and the pulsing seal show it's this screen, not a picture of one.
struct VerifiedHandoffCard: View {
    var role: Speaker
    var amount: Int
    var fingerprint: String
    var verifiedAt: Date?
    var item: String
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.green.opacity(0.18))
                    .frame(width: 150, height: 150)
                    .scaleEffect(pulse ? 1.08 : 0.92)
                    .animation(.easeInOut(duration: 1.1).repeatForever(), value: pulse)
                Circle().fill(Color.green.gradient).frame(width: 116, height: 116)
                Image(systemName: "checkmark")
                    .font(.system(size: 60, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .padding(.top, 4)

            Text("Payment verified")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(.green)
            Text(role == .seller ? "Hand over the item" : "Seller can hand over the item")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            Text(Money.format(amount, alwaysShowCents: true))
                .font(.system(size: 46, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(item).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)

            HStack(spacing: 0) {
                fact("Agreement", fingerprint, mono: true)
                Divider().frame(height: 34)
                fact("Paid", TimeFormat.clock(verifiedAt ?? Date()), mono: false)
                Divider().frame(height: 34)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    fact("Verified", Self.ago(verifiedAt, now: ctx.date), mono: false)
                }
            }
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.10)))

            Label(role == .seller
                  ? "Confirmed by DEAL on this terminal, not a screenshot. The buyer's phone shows the same."
                  : "Confirmed by DEAL on both phones, so no \u{201C}payment sent\u{201D} screenshots.",
                  systemImage: "checkmark.shield.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.green.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.green, lineWidth: 3))
        .onAppear { pulse = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("verifiedHandoff")
    }

    private func fact(_ label: String, _ value: String, mono: Bool) -> some View {
        VStack(spacing: 2) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value)
                .font(mono ? .subheadline.monospaced().weight(.semibold) : .subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "just now" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return TimeFormat.clock(date)
    }
}

/// Minimal wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// A `condition_check` event in the B3 transcript (it isn't something anyone said).
struct ConditionCheckLineView: View {
    var event: DealEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "camera.viewfinder")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let cue = event.cue, !cue.isEmpty {
                    Text(cue).font(.subheadline.weight(.semibold))
                }
                Text(event.text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let ts = event.timestamp {
                Text(TimeFormat.clock(ts)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }
}
