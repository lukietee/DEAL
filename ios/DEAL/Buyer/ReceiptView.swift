import SwiftUI

/// B6 (buyer) and S5 (seller): amount, merchant, time, Stripe test payment ID,
/// agreement fingerprint, and the summary "Asked $38,000, paid $34,600, blocked $1,200".
/// Marketplace sessions lead with the "Payment verified, hand over the item" card on both phones.
struct ReceiptView: View {
    @Environment(AppModel.self) private var model
    var store: SessionStore
    @State private var appeared = false

    var body: some View {
        let state = store.state
        let amount = state.receipt?.amount ?? state.agreement?.total ?? 0
        ScrollView {
            HeroScaffold(heroBottomPadding: 64) {
                if store.isMarketplace {
                    // Marketplace meetup: the anti-scam handoff moment comes first, on both phones.
                    VerifiedHandoffCard(
                        role: store.role,
                        amount: amount,
                        fingerprint: Fingerprint.short(state.receipt?.agreementFingerprint ?? state.agreement?.fingerprint),
                        verifiedAt: state.receipt?.createdAt,
                        item: state.session.item)
                        .scaleEffect(appeared ? 1 : 0.85)
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(duration: 0.5, bounce: 0.35), value: appeared)
                        .padding(.top, 8)
                } else {
                    paymentHero(state, amount: amount)
                }
            } content: {
                VStack(alignment: .leading, spacing: 14) {
                    if store.role == .buyer {
                        summaryTiles(state, amount: amount)
                    }
                    if let receipt = state.receipt {
                        receiptCard(state, receipt)
                        Text(receipt.mock ? "Simulated payment · backend mock mode"
                                          : "Stripe test mode · Visa test card. No real money moved.")
                            .font(DealFont.jakarta(12))
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.top, 24)
            }
        }
        .buyerHeroUnderlay()
        .dealPage()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LedgerDock {
                // Buyer: back to B1 Home (the deal is now in Purchase History). Seller: mode picker.
                Button("Done") {
                    if store.role == .buyer { model.endSession() } else { model.exitToModePicker() }
                }
                .buttonStyle(PillButtonStyle(kind: .sand, height: 58))
            }
        }
        .navigationTitle(store.role == .buyer ? "Receipt" : "Payment received")
        .dealInlineTitle()
        .buyerClearNavBar()
        .onAppear {
            appeared = true
            Platform.haptic(.success)
            if store.role == .buyer { model.glasses.clear() }
        }
    }

    // MARK: Hero

    private func paymentHero(_ state: SessionState, amount: Int) -> some View {
        let exact = state.agreement.map { $0.total == amount } ?? false
        return VStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 28, weight: .heavy))
                .frame(width: 64, height: 64)
                .background(Circle().fill(Palette.surface))
                .background(Circle().fill(Palette.green.opacity(0.25)).padding(-8))
                .scaleEffect(appeared ? 1 : 0.4)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(duration: 0.5, bounce: 0.4), value: appeared)
                .padding(.bottom, 4)
            Text("Payment complete")
                .font(DealFont.jakarta(15, .bold))
                .foregroundStyle(Palette.inkSoft)
            Text(Money.format(amount, alwaysShowCents: true))
                .font(DealFont.jakarta(52, .extrabold))
                .kerning(-2.3)
                .lineLimit(1).minimumScaleFactor(0.5)
            if exact {
                Text(store.role == .buyer ? "Exactly the locked amount" : "Charged exactly the agreed amount")
                    .font(DealFont.caption)
                    .foregroundStyle(Palette.mutedWarm)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: Asked / paid / blocked

    private func summaryTiles(_ state: SessionState, amount: Int) -> some View {
        let asked = state.receipt?.askingPrice ?? state.session.askingPrice
        let blocked = state.blockedTotal
        return HStack(spacing: 10) {
            tile(Money.format(asked), "Asked", strike: true)
            tile(Money.format(amount), "Paid", fill: Palette.sand, labelColor: Palette.mutedWarm)
            tile(Money.format(blocked), "Blocked", valueColor: blocked > 0 ? Palette.red : Palette.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.receiptSummary)
    }

    private func tile(_ value: String, _ label: String, strike: Bool = false, fill: Color = Palette.surface,
                      valueColor: Color = Palette.ink, labelColor: Color = Palette.muted) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(DealFont.jakarta(20, .extrabold))
                .kerning(-0.4)
                .strikethrough(strike)
                .foregroundStyle(strike ? Palette.navInactive : valueColor)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label.uppercased())
                .font(DealFont.jakarta(11, .bold)).kerning(1.3)
                .foregroundStyle(labelColor)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(fill))
    }

    // MARK: Receipt rows

    private func receiptCard(_ state: SessionState, _ receipt: Receipt) -> some View {
        LedgerCard {
            row("Item", state.session.item)
            LedgerDivider()
            row("Merchant", receipt.merchant ?? "Seller")
            LedgerDivider()
            row("Time", TimeFormat.full(receipt.createdAt))
            LedgerDivider()
            HStack {
                Text("Status").font(DealFont.jakarta(15, .semibold)).foregroundStyle(Palette.muted)
                Spacer()
                HStack(spacing: 6) {
                    let ok = ["succeeded", "paid", "complete", "completed"].contains(receipt.status.lowercased())
                    Circle().fill(ok ? Palette.greenText : Palette.amber).frame(width: 8, height: 8)
                    Text(receipt.status.capitalizedFirst).font(DealFont.jakarta(15, .bold))
                }
            }
            .padding(.vertical, 13)
            LedgerDivider()
            HStack(spacing: 16) {
                Text("Payment ID").font(DealFont.jakarta(15, .semibold)).foregroundStyle(Palette.muted)
                Spacer()
                Text(receipt.stripePaymentId)
                    .font(DealFont.mono(13))
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 13)
            LedgerDivider()
            HStack {
                Text("Agreement").font(DealFont.jakarta(15, .semibold)).foregroundStyle(Palette.muted)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 11, weight: .bold))
                    Text(Fingerprint.short(receipt.agreementFingerprint)).font(DealFont.mono(13, .semibold))
                }
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(Palette.sand))
            }
            .padding(.vertical, 12)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).font(DealFont.jakarta(15, .semibold)).foregroundStyle(Palette.muted)
            Spacer()
            Text(value)
                .font(DealFont.jakarta(15, .bold))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 13)
    }
}
