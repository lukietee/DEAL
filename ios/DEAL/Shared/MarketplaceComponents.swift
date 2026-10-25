import SwiftUI

// Marketplace pieces shared by B2 (listing card), B3 (claims strip, discrepancy card) and
// B6 / S5 (verified handoff).

/// B2: compact card for an imported listing (title, asking price, source, condition claims).
struct ListingCard: View {
    var listing: Listing
    var note: String? = nil
    var onRemove: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: listing.isFacebookMarketplace ? "storefront.fill" : "doc.text")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Palette.sand))
                Text(listing.sourceDisplayName.uppercased())
                    .font(DealFont.jakarta(11, .extrabold))
                    .kerning(1.2)
                    .foregroundStyle(Palette.muted)
                Spacer()
                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Palette.surface))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove listing")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(listing.title).font(DealFont.jakarta(17, .extrabold)).lineLimit(2)
                Spacer(minLength: 8)
                Text(Money.format(listing.askingPrice))
                    .font(DealFont.jakarta(24, .extrabold))
                    .kerning(-0.6)
            }
            let meta = [listing.location, listing.sellerName].compactMap { $0 }.filter { !$0.isEmpty }
            if !meta.isEmpty {
                Text(meta.joined(separator: " · ")).font(DealFont.caption).foregroundStyle(Palette.muted)
            }
            if !listing.conditionClaims.isEmpty {
                Text("Seller claims")
                    .font(DealFont.jakarta(12, .bold))
                    .foregroundStyle(Palette.muted)
                    .padding(.top, 2)
                ClaimChips(claims: listing.conditionClaims, wrap: true)
            }
            if let note {
                Text(note).font(DealFont.jakarta(11)).foregroundStyle(Palette.muted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.surfaceWarm))
        .foregroundStyle(Palette.ink)
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
    /// Chip fill for unflagged claims (sand on white cards; white on the sand hero).
    var fill: Color = Palette.sand

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
            HStack(spacing: 5) {
                Image(systemName: bad ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(bad ? Palette.red : Palette.inkSoft)
                Text(claim)
                    .strikethrough(bad, color: Palette.red)
            }
            .font(DealFont.jakarta(13, .semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(bad ? Palette.red.opacity(0.12) : fill))
            .foregroundStyle(bad ? Palette.red : Palette.ink)
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
        HStack(alignment: compact ? .center : .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: compact ? 14 : 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: compact ? 32 : 44, height: compact ? 32 : 44)
                .background(Circle().fill(Palette.red))
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                if !compact {
                    Text("CONDITION MISMATCH")
                        .font(DealFont.jakarta(11, .extrabold)).kerning(1.2)
                        .foregroundStyle(Palette.red)
                }
                (Text("Listing: ").foregroundStyle(Palette.muted) + Text(discrepancy.claim).fontWeight(.bold)
                 + Text("  ·  Seen: ").foregroundStyle(Palette.muted) + Text(discrepancy.observed).fontWeight(.bold))
                    .font(DealFont.jakarta(compact ? 13 : 15))
                    .lineLimit(compact ? 1 : 3)
                    .minimumScaleFactor(0.8)
                if !compact, let cue = discrepancy.cue, !cue.isEmpty {
                    Text("Glasses: \u{201C}\(cue)\u{201D}").font(DealFont.caption).foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if let discount = discrepancy.suggestedDiscount, discount > 0 {
                    Text("ask \(Money.format(discount)) off")
                        .font(DealFont.jakarta(compact ? 13 : 16, .extrabold))
                        .foregroundStyle(Palette.greenText)
                        .lineLimit(1)
                }
                if moreCount > 0 {
                    Text("+\(moreCount) more").font(DealFont.jakarta(11)).foregroundStyle(Palette.muted)
                }
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(.vertical, compact ? 10 : 16)
        .padding(.horizontal, compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: compact ? 24 : 28, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: compact ? 24 : 28, style: .continuous)
            .strokeBorder(Palette.red.opacity(0.55), lineWidth: 1.5))
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
                Circle().fill(Palette.green.opacity(0.22))
                    .frame(width: 150, height: 150)
                    .scaleEffect(pulse ? 1.08 : 0.92)
                    .animation(.easeInOut(duration: 1.1).repeatForever(), value: pulse)
                Circle().fill(Palette.greenText).frame(width: 116, height: 116)
                Image(systemName: "checkmark")
                    .font(.system(size: 56, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .padding(.top, 4)

            Text("Payment verified")
                .font(DealFont.jakarta(32, .extrabold))
                .kerning(-0.8)
                .foregroundStyle(Palette.greenText)
            Text(role == .seller ? "Hand over the item" : "Seller can hand over the item")
                .font(DealFont.jakarta(20, .bold))
                .multilineTextAlignment(.center)

            Text(Money.format(amount, alwaysShowCents: true))
                .font(DealFont.jakarta(44, .extrabold))
                .kerning(-1.5)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(item).font(DealFont.jakarta(14)).foregroundStyle(Palette.muted).lineLimit(1)

            HStack(spacing: 0) {
                fact("Agreement", fingerprint, mono: true)
                Rectangle().fill(Palette.divider).frame(width: 1, height: 34)
                fact("Paid", TimeFormat.clock(verifiedAt ?? Date()), mono: false)
                Rectangle().fill(Palette.divider).frame(width: 1, height: 34)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    fact("Verified", Self.ago(verifiedAt, now: ctx.date), mono: false)
                }
            }
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.surfaceWarm))

            Label(role == .seller
                  ? "Confirmed by DEAL on this terminal, not a screenshot. The buyer's phone shows the same."
                  : "Confirmed by DEAL on both phones, so no \u{201C}payment sent\u{201D} screenshots.",
                  systemImage: "checkmark.shield.fill")
                .font(DealFont.caption)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(Palette.ink)
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Palette.green, lineWidth: 3))
        .onAppear { pulse = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("verifiedHandoff")
    }

    private func fact(_ label: String, _ value: String, mono: Bool) -> some View {
        VStack(spacing: 3) {
            Text(label.uppercased()).font(DealFont.jakarta(10, .bold)).kerning(1).foregroundStyle(Palette.muted)
            Text(value)
                .font(mono ? DealFont.mono(14, .semibold) : DealFont.jakarta(14, .bold))
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.ink)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.sand))
            VStack(alignment: .leading, spacing: 2) {
                if let cue = event.cue, !cue.isEmpty {
                    Text(cue).font(DealFont.jakarta(14, .bold))
                }
                Text(event.text).font(DealFont.caption).foregroundStyle(Palette.muted).lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let ts = event.timestamp {
                Text(TimeFormat.clock(ts)).font(DealFont.jakarta(11)).foregroundStyle(Palette.muted)
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.surface))
    }
}
