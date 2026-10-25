import SwiftUI

/// Seller mode container: S1 until joined, then routes by `SessionState.sellerPhase`
/// (S2 -> S3 -> S4 -> S5).
/// S1, S2 and S4 draw their own header (round back button in the sand hero), so the
/// navigation bar is hidden for them; S3 / S5 keep the bar with its Exit button.
struct SellerFlowView: View {
    @Environment(AppModel.self) private var model

    private var sellerStore: SessionStore? {
        guard let store = model.activeStore, store.role == .seller else { return nil }
        return store
    }

    private var ownsHeader: Bool {
        guard let store = sellerStore else { return true }
        switch store.state.sellerPhase {
        case .live, .terminal: return true
        case .agreement, .receipt: return false
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let store = sellerStore {
                    SellerSessionView(store: store)
                } else {
                    JoinSessionView()
                }
            }
            .toolbar {
                if !ownsHeader {
                    ToolbarItem(placement: .dealLeading) {
                        Button { model.exitToModePicker() } label: {
                            Label("Exit", systemImage: "chevron.backward")
                        }
                    }
                }
            }
            .sellerNavBarHidden(ownsHeader)
        }
    }
}

extension View {
    /// Hides the navigation bar (iOS) for seller screens that draw their own header.
    @ViewBuilder
    func sellerNavBarHidden(_ hidden: Bool) -> some View {
        #if os(iOS)
        self.toolbar(hidden ? .hidden : .automatic, for: .navigationBar)
        #else
        self
        #endif
    }
}

/// Round back button used in the seller headers. Same action as the old "Exit" toolbar item.
struct SellerExitButton: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat = 44

    var body: some View {
        CircleIconButton(systemName: "chevron.left", size: size) { model.exitToModePicker() }
            .accessibilityLabel("Exit")
    }
}

struct SellerSessionView: View {
    var store: SessionStore

    var body: some View {
        let phase = store.state.sellerPhase
        VStack(spacing: 0) {
            if let error = store.bannerMessage {
                ErrorBanner(message: error) { store.clearError() }.padding(.top, 6)
            }
            switch phase {
            case .live: SellerLiveView(store: store)
            case .agreement: AgreementReviewView(store: store)
            case .terminal: TerminalView(store: store)
            case .receipt: ReceiptView(store: store)
            }
        }
        .animation(.default, value: phase)
    }
}

/// S2. Live View: item, current offer, terms list. No cues and no transcript.
struct SellerLiveView: View {
    var store: SessionStore

    var body: some View {
        let state = store.state
        ScrollView {
            HeroScaffold(heroBottomPadding: 80) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        SellerExitButton()
                        Spacer()
                        Text(state.session.joinCode)
                            .font(DealFont.mono(15, .semibold))
                            .kerning(1.5)
                            .accessibilityLabel("Session \(state.session.joinCode)")
                        Spacer()
                        LivePill()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.session.item)
                            .font(DealFont.jakarta(30, .extrabold))
                            .kerning(-0.9)
                            .fixedSize(horizontal: false, vertical: true)
                        if let asking = state.session.askingPrice {
                            Text("Your asking price \(Money.format(asking))")
                                .font(DealFont.jakarta(15))
                                .foregroundStyle(Palette.mutedWarm)
                        }
                    }
                }
            } content: {
                offerCard(state)
                    .padding(.top, -40)
                    .padding(.trailing, 20)

                SectionHeader(title: "Terms so far")
                    .padding(.top, 4)
                termsCard(state.visibleTerms)

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 18))
                        .padding(.top, 1)
                    Text("When the buyer locks the deal, you'll confirm the agreement here. Your terminal then charges exactly that amount.")
                        .font(DealFont.jakarta(14))
                        .lineSpacing(3)
                        .foregroundStyle(Color(hex: 0x2E2E2E))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(hex: 0xD9D9D9)))
                .padding(.top, 8)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(alignment: .top) { Palette.sand.frame(height: 200).ignoresSafeArea(edges: .top) }
        .dealPage()
    }

    private func offerCard(_ state: SessionState) -> some View {
        VStack(spacing: 8) {
            Text(Money.format(state.currentOffer, placeholder: "—"))
                .font(DealFont.jakarta(60, .extrabold))
                .kerning(-2.7)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .animation(.default, value: state.currentOffer)
            Text(offerCaption(state.currentOfferBy))
                .font(DealFont.jakarta(12, .extrabold))
                .kerning(1.4)
                .foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(Palette.surface)
            .shadow(color: .black.opacity(0.12), radius: 9, y: 6))
        .accessibilityElement(children: .combine)
    }

    private func offerCaption(_ by: Speaker?) -> String {
        switch by {
        case .seller: "CURRENT OFFER · YOURS"
        case .buyer: "CURRENT OFFER · BUYER'S"
        default: "CURRENT OFFER"
        }
    }

    private func termsCard(_ terms: [Term]) -> some View {
        VStack(spacing: 0) {
            if terms.isEmpty {
                Text("No terms yet")
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
            }
            ForEach(Array(terms.enumerated()), id: \.element.id) { index, term in
                let parts = SellerTermParts(term)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    HStack(spacing: 6) {
                        Text(parts.label).font(DealFont.jakarta(16, .semibold))
                        if term.uncertain {
                            Text("(?)").font(DealFont.jakarta(14, .bold)).foregroundStyle(Palette.amber)
                        }
                    }
                    Spacer(minLength: 8)
                    if let value = parts.value {
                        Text(value).font(DealFont.jakarta(16, .extrabold))
                    }
                }
                .padding(.vertical, 14)
                .overlay(alignment: .bottom) {
                    if index < terms.count - 1 { Rectangle().fill(Palette.divider).frame(height: 1) }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
    }
}

/// Splits a term into the S2 "label ........ value" row (same wording rules as `TermDisplay`).
private struct SellerTermParts {
    var label: String
    var value: String?

    init(_ term: Term) {
        let name = term.label.prefix(1).uppercased() + term.label.dropFirst()
        switch term.type {
        case "price":
            label = "Price"; value = Money.format(term.amount, placeholder: "?")
        case "item":
            label = name; value = "Included"
        case "fee":
            label = name; value = term.amount == 0 ? "Waived" : Money.format(term.amount, placeholder: "?")
        default:
            label = name
            if let amount = term.amount, amount != 0 { value = Money.format(amount) } else { value = nil }
        }
    }
}

/// "● LIVE" capsule in the S2 hero.
private struct LivePill: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Palette.liveDot).frame(width: 7, height: 7)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(), value: pulse)
            Text("LIVE").font(DealFont.jakarta(12, .extrabold)).kerning(1.4)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(Palette.ink.opacity(0.12)))
        .onAppear { pulse = true }
    }
}
