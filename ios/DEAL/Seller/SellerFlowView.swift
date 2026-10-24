import SwiftUI

/// Seller mode container: S1 until joined, then routes by `SessionState.sellerPhase`
/// (S2 -> S3 -> S4 -> S5).
struct SellerFlowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if let store = model.activeStore, store.role == .seller {
                    SellerSessionView(store: store)
                } else {
                    JoinSessionView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .dealLeading) {
                    Button { model.exitToModePicker() } label: {
                        Label("Exit", systemImage: "chevron.backward")
                    }
                }
            }
        }
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
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(state.session.item).font(.title3.weight(.bold))
                        Spacer()
                        LiveBadge(color: .orange)
                    }
                    Text("Asking \(Money.format(state.session.askingPrice))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Section("Current offer") {
                HStack {
                    Text(Money.format(state.currentOffer, placeholder: "—"))
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                        .animation(.default, value: state.currentOffer)
                    Spacer()
                    if let by = state.currentOfferBy {
                        Text(by == .seller ? "your offer" : "buyer's offer").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Terms") {
                let terms = state.visibleTerms
                if terms.isEmpty {
                    Text("No terms yet").foregroundStyle(.secondary)
                }
                ForEach(terms) { term in
                    HStack {
                        Text(TermDisplay.text(term))
                        if term.uncertain { Text("(?)").foregroundStyle(.orange) }
                    }
                }
            }
            Section {
                Label("The buyer will lock the deal; you'll confirm the agreement here.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Session \(state.session.joinCode)")
        .dealInlineTitle()
    }
}
