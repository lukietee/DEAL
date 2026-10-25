import SwiftUI

/// B5. Charge Alert: red banner "Charge blocked: $1,200 more than agreed", agreed vs requested
/// side by side with the extra line highlighted, the contradicting transcript line with its
/// time, a one-sentence AI explanation, and Reject (default) / Approve change.
struct ChargeAlertView: View {
    var store: SessionStore
    var request: PaymentRequest
    var onDone: () -> Void
    @State private var confirmApprove = false
    @State private var deciding = false

    private static let alertRed = Color(hex: 0xE5483B)

    var body: some View {
        let state = store.state
        let agreement = state.agreement
        let extra = ChargeMath.extraAmount(request: request, agreement: agreement)
        let extras = ChargeMath.extraLineItems(request: request, agreement: agreement)
        let agreedTotal = request.mismatch?.agreedTotal ?? agreement?.total ?? 0
        let requestedTotal = request.mismatch?.requestedTotal ?? request.amount

        ScrollView {
            HeroScaffold(heroBottomPadding: 68) {
                banner(extra: extra, requestedTotal: requestedTotal, item: state.session.item)
            } content: {
                VStack(alignment: .leading, spacing: 14) {
                    comparison(agreement: agreement, extras: extras, agreedTotal: agreedTotal, requestedTotal: requestedTotal)
                    if let quote = contradictingLine(state) {
                        quoteCard(quote)
                    }
                    if let explanation = request.mismatchExplanation, !explanation.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "sparkles").font(.system(size: 18, weight: .semibold))
                            Text(explanation)
                                .font(DealFont.jakarta(14))
                                .foregroundStyle(Palette.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.top, 24)
            }
        }
        .buyerHeroUnderlay()
        .dealPage()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actions(agreedTotal: agreedTotal, requestedTotal: requestedTotal)
        }
        .confirmationDialog("Approve the extra \(Money.format(max(extra, 0)))? The agreement will be amended and re-fingerprinted.",
                            isPresented: $confirmApprove, titleVisibility: .visible) {
            Button("Approve change", role: .destructive) { decide(.approve) }
            Button("Cancel", role: .cancel) {}
        }
        .interactiveDismissDisabled()
    }

    // MARK: Hero

    private func banner(extra: Int, requestedTotal: Int, item: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Self.alertRed))
                Text("CHARGE BLOCKED")
                    .font(DealFont.jakarta(12, .extrabold)).kerning(1.7)
                    .foregroundStyle(Palette.liveRed)
                    .padding(.horizontal, 14).frame(height: 30)
                    .background(Capsule().fill(Self.alertRed.opacity(0.2)))
            }
            Group {
                if extra > 0 {
                    let amount = Text(Money.format(extra)).foregroundColor(Palette.liveRed)
                    Text("\(amount) more\nthan agreed")
                } else {
                    Text("Charge doesn't match the agreement")
                }
            }
            .font(DealFont.jakarta(44, .extrabold))
            .kerning(-1.8)
            .lineSpacing(-4)
            .minimumScaleFactor(0.6)
            .accessibilityLabel(extra > 0 ? "Charge blocked: \(Money.format(extra)) more than agreed"
                                          : "Charge blocked: doesn't match the agreement")
            Text("The seller tried to charge \(Money.format(requestedTotal)) for the \(item).")
                .font(DealFont.jakarta(15))
                .foregroundStyle(Palette.mutedWarm)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    // MARK: Agreed vs requested

    private struct CompareRow: Identifiable {
        var id: String
        var label: String
        var agreed: String
        var requested: String
        var highlighted: Bool
    }

    /// Union of the agreement's lines and the request's lines, matched by label.
    private func compareRows(agreement: Agreement?, extras: [LineItem]) -> [CompareRow] {
        let extraLabels = Set(extras.map { $0.label.lowercased() })
        let included = Set((agreement?.items.dropFirst() ?? []).map { $0.lowercased() })
        let agreedLines = agreement.map { SessionState.lines(for: $0) } ?? []
        func show(_ li: LineItem?) -> String {
            guard let li else { return "none" }
            if li.amount == 0, included.contains(li.label.lowercased()) { return "Incl." }
            return Money.format(li.amount)
        }
        var rows: [CompareRow] = []
        var seen = Set<String>()
        for li in agreedLines {
            let key = li.label.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let req = request.lineItems.first { $0.label.lowercased() == key }
            rows.append(CompareRow(id: key, label: li.label.capitalizedFirst, agreed: show(li), requested: show(req),
                                   highlighted: extraLabels.contains(key)))
        }
        for li in request.lineItems where !seen.contains(li.label.lowercased()) {
            let key = li.label.lowercased()
            seen.insert(key)
            let isExtra = extraLabels.contains(key)
            rows.append(CompareRow(id: key, label: li.label.capitalizedFirst, agreed: "none",
                                   requested: isExtra && li.amount > 0 ? Money.formatDelta(li.amount) : show(li),
                                   highlighted: isExtra))
        }
        return rows
    }

    private func comparison(agreement: Agreement?, extras: [LineItem], agreedTotal: Int, requestedTotal: Int) -> some View {
        VStack(spacing: 0) {
            compareLine(label: "", agreed: "AGREED", requested: "REQUESTED")
                .font(DealFont.jakarta(11, .extrabold)).kerning(1.3)
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            ForEach(compareRows(agreement: agreement, extras: extras)) { row in
                if row.highlighted {
                    HStack(spacing: 8) {
                        Text(row.label).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                        Text(row.agreed).foregroundStyle(Palette.navInactive).fontWeight(.semibold)
                            .frame(width: 80, alignment: .trailing)
                        Text(row.requested).foregroundStyle(Palette.liveRed)
                            .frame(width: 96, alignment: .trailing)
                    }
                    .font(DealFont.jakarta(15, .extrabold))
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.sand))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                } else {
                    compareLine(label: row.label, agreed: row.agreed, requested: row.requested)
                        .font(DealFont.jakarta(15, .semibold))
                        .padding(.horizontal, 20).padding(.vertical, 10)
                }
            }
            HStack(spacing: 8) {
                Text("Total").frame(maxWidth: .infinity, alignment: .leading)
                Text(Money.format(agreedTotal)).frame(width: 80, alignment: .trailing)
                Text(Money.format(requestedTotal)).foregroundStyle(Palette.red).frame(width: 96, alignment: .trailing)
            }
            .font(DealFont.jakarta(18, .extrabold))
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 16)
        }
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agreed versus requested")
    }

    private func compareLine(label: String, agreed: String, requested: String) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
            Text(agreed).frame(width: 80, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.7)
            Text(requested).frame(width: 96, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    // MARK: Quote

    private struct Quote { var text: String; var speaker: String; var time: Date? }

    private func quoteCard(_ quote: Quote) -> some View {
        SurfaceCard(padding: 20) {
            Text("YOU AGREED")
                .font(DealFont.jakarta(11, .extrabold)).kerning(1.3)
                .foregroundStyle(Palette.muted)
            Text("“\(quote.text)”")
                .font(DealFont.jakarta(16, .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let ts = quote.time {
                Text("\(quote.speaker) · \(TimeFormat.clock(ts))")
                    .font(DealFont.mono(12))
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    /// Backend-provided source line first; else the agreement's last source event.
    private func contradictingLine(_ state: SessionState) -> Quote? {
        if let m = request.mismatch, let text = m.sourceEventText {
            let speaker = state.event(id: m.sourceEventId)?.speaker.displayName ?? "Seller"
            return Quote(text: text, speaker: speaker, time: m.sourceEventTimestamp ?? state.event(id: m.sourceEventId)?.timestamp)
        }
        if let id = state.agreement?.sourceEventIds.last, let e = state.event(id: id) {
            return Quote(text: e.text, speaker: e.speaker.displayName, time: e.timestamp)
        }
        return nil
    }

    // MARK: Actions

    private func actions(agreedTotal: Int, requestedTotal: Int) -> some View {
        LedgerDock {
            Button { decide(.reject) } label: {
                HStack(spacing: 10) {
                    if deciding { ProgressView().tint(Palette.ink) }
                    Text("Reject · keep \(Money.format(agreedTotal))")
                }
            }
            .buttonStyle(PillButtonStyle(kind: .sand, height: 58))
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Reject")
            Button("Approve change to \(Money.format(requestedTotal))") { confirmApprove = true }
                .font(DealFont.jakarta(15, .semibold))
                .foregroundStyle(Palette.muted)
                .frame(height: 44)
                .accessibilityLabel("Approve change")
        }
        .disabled(deciding)
    }

    private func decide(_ decision: PaymentDecision) {
        deciding = true
        Task {
            await store.decide(request, decision)
            deciding = false
            Platform.haptic(decision == .reject ? .success : .warning)
            onDone()
        }
    }
}

extension SessionState {
    /// Agreement shown as line items (price on the main item, included items at $0, fees).
    static func lines(for agreement: Agreement) -> [LineItem] {
        var items = [LineItem(label: agreement.items.first ?? "Price", amount: agreement.price)]
        items += agreement.items.dropFirst().map { LineItem(label: $0, amount: 0) }
        items += agreement.fees.map { LineItem(label: $0.label, amount: $0.amount) }
        return items
    }
}
