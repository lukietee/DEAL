import SwiftUI

/// B1. Home: Start Negotiation, the active session (if one is running), recent purchases,
/// and totals (amount spent, extra charges blocked).
struct BuyerHomeView: View {
    @Environment(AppModel.self) private var model
    @Binding var path: [BuyerRoute]
    /// `nil` = resume this phone's session; a `Session` = re-attach to one from the backend.
    var onResume: (Session?) -> Void

    @State private var sessions: [Session] = []
    @State private var loading = false
    @State private var loadError: String?

    private var purchases: [Session] { PurchaseHistory.purchases(sessions) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button { path.append(.newNegotiation) } label: {
                    Label("Start Negotiation", systemImage: "plus.bubble.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("startNegotiation")

                activeSessionCard
                totalsCard
                recentCard
            }
            .padding()
        }
        .navigationTitle("DEAL")
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: Active session

    @ViewBuilder
    private var activeSessionCard: some View {
        if let store = model.activeStore, store.role == .buyer, store.state.buyerPhase != .receipt {
            let state = store.state
            sessionCard(state.session, offer: state.currentOffer, phase: phaseLabel(state)) { onResume(nil) }
        } else if let open = PurchaseHistory.resumable(sessions) {
            sessionCard(open, offer: open.currentOffer, phase: phaseLabel(open.status)) { onResume(open) }
        }
    }

    private func sessionCard(_ session: Session, offer: Int?, phase: String, resume: @escaping () -> Void) -> some View {
        Button(action: resume) {
            Card(title: "Active session", tint: Theme.accent) {
                HStack(alignment: .firstTextBaseline) {
                    Label(session.item, systemImage: session.category.symbol)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    LiveBadge(text: phase)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Current offer").foregroundStyle(.secondary)
                    Spacer()
                    Text(Money.format(offer, placeholder: "—")).font(.title3.weight(.bold).monospacedDigit())
                }
                OfferProgressBar(asking: session.askingPrice, target: session.targetPrice,
                                 maxBudget: session.maxBudget, offer: offer)
                HStack {
                    Text("Code \(session.joinCode)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Text("Resume").font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .foregroundStyle(Theme.accent)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("resumeSession")
    }

    private func phaseLabel(_ state: SessionState) -> String {
        guard let agreement = state.agreement else { return "LIVE" }
        return agreement.isLocked ? "LOCKED" : "REVIEW"
    }

    private func phaseLabel(_ status: SessionStatus) -> String {
        switch status {
        case .agreementDraft: "REVIEW"
        case .locked: "LOCKED"
        default: "LIVE"
        }
    }

    // MARK: Totals

    private var totalsCard: some View {
        let totals = PurchaseHistory.totals(sessions)
        return Card(title: "Totals") {
            HStack(alignment: .top, spacing: 12) {
                totalTile("Amount spent", Money.format(totals.spent), color: .primary, id: "totalSpent")
                totalTile("Extra charges blocked", Money.format(totals.blocked), color: .red, id: "totalBlocked")
            }
            Text(totals.count == 0
                 ? "No purchases yet."
                 : "\(totals.count) purchase\(totals.count == 1 ? "" : "s") · saved \(Money.format(totals.saved)) vs asking")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func totalTile(_ label: String, _ value: String, color: Color, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
                .accessibilityIdentifier(id)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Recent purchases

    private var recentCard: some View {
        Card(title: "Recent purchases") {
            if let loadError {
                Text(loadError).font(.footnote).foregroundStyle(.red)
            }
            if purchases.isEmpty {
                if loading {
                    ProgressView()
                } else if loadError == nil {
                    Text("Deals you pay for with DEAL show up here.").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                ForEach(purchases.prefix(3)) { session in
                    Button { path.append(.deal(session)) } label: {
                        PurchaseRow(session: session)
                    }
                    .buttonStyle(.plain)
                    if session.id != purchases.prefix(3).last?.id { Divider() }
                }
            }
            Button { path.append(.history) } label: {
                HStack {
                    Text("Purchase History")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(.top, 4)
            .accessibilityIdentifier("purchaseHistory")
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            sessions = try await model.api.listSessions()
            loadError = nil
        } catch {
            loadError = "Couldn't load purchases (\(error.localizedDescription))"
        }
    }
}

/// One purchase: item, final price, savings vs asking, date. Used on B1 and B7.
struct PurchaseRow: View {
    var session: Session

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: session.category.symbol)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.item).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(TimeFormat.full(session.dealDate)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.format(session.finalPrice, placeholder: "—"))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                if let saved = session.savingsVsAsking, saved > 0 {
                    Text("saved \(Money.format(saved))").font(.caption.monospacedDigit()).foregroundStyle(.green)
                } else if let saved = session.savingsVsAsking, saved < 0 {
                    Text("\(Money.format(-saved)) over asking").font(.caption.monospacedDigit()).foregroundStyle(.red)
                }
            }
        }
        .contentShape(Rectangle())
    }
}
