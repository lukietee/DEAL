import SwiftUI

/// B4 (buyer) and S3 (seller): the same agreement on both phones.
/// Final price, included items, fees, total; each term links to its source transcript line
/// (buyer only — the transcript is private to the buyer); open questions; Confirm + the other
/// side's status; "Agreement locked" badge with the short fingerprint after both confirm.
struct AgreementReviewView: View {
    var store: SessionStore
    var onKeepNegotiating: (() -> Void)? = nil
    @State private var expandedSource: String?

    private var isBuyer: Bool { store.role == .buyer }

    var body: some View {
        let state = store.state
        ScrollView {
            if let agreement = state.agreement {
                VStack(alignment: .leading, spacing: 16) {
                    header(state.session, agreement)
                    termsCard(state, agreement)
                    if !agreement.openQuestions.isEmpty {
                        Card(title: "Open questions", tint: .orange) {
                            ForEach(agreement.openQuestions, id: \.self) { q in
                                Label(q, systemImage: "questionmark.circle").font(.subheadline)
                            }
                        }
                    }
                    if isBuyer, !agreement.sourceEventIds.isEmpty {
                        sourcesCard(state, agreement)
                    }
                    confirmationsCard(agreement)
                    if agreement.isLocked {
                        lockedFooter(agreement)
                    }
                }
                .padding()
            } else {
                ProgressView("Drafting agreement…").padding(.top, 80)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let agreement = state.agreement, !agreement.isConfirmed(by: store.role) {
                VStack(spacing: 8) {
                    Button {
                        Task {
                            await store.confirmAgreement()
                            Platform.haptic(.success)
                        }
                    } label: {
                        HStack {
                            if store.isBusy { ProgressView().tint(.white) }
                            Text("Confirm \(Money.format(agreement.total))")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(store.isBusy)
                    if let onKeepNegotiating, isBuyer {
                        Button("Keep negotiating", action: onKeepNegotiating).font(.subheadline)
                    }
                }
                .padding()
                .background(.bar)
            }
        }
        .navigationTitle(isBuyer ? "Agreement Review" : "Agreement")
        .dealInlineTitle()
    }

    private func header(_ session: Session, _ agreement: Agreement) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.item).font(.title2.weight(.bold))
            HStack {
                if agreement.isLocked {
                    Label("Agreement locked", systemImage: "lock.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.green.opacity(0.18)))
                        .foregroundStyle(.green)
                    Text(Fingerprint.short(agreement))
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Label("Draft · needs both confirmations", systemImage: "doc.text")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if agreement.fingerprintValid == false {
                    Label("Fingerprint mismatch", systemImage: "exclamationmark.shield.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                if agreement.version > 1 {
                    Text("v\(agreement.version)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func termsCard(_ state: SessionState, _ agreement: Agreement) -> some View {
        Card(title: "Terms") {
            LabeledAmountRow(label: agreement.items.first ?? state.session.item, amount: agreement.price, note: "Final price")
            ForEach(agreement.items.dropFirst(), id: \.self) { item in
                HStack {
                    Text(item.capitalizedFirst)
                    Spacer()
                    Text("Included").foregroundStyle(.secondary)
                }
            }
            if !agreement.fees.isEmpty { Divider() }
            ForEach(agreement.fees, id: \.self) { fee in
                LabeledAmountRow(label: fee.label.capitalizedFirst, amount: fee.amount,
                                 note: fee.note ?? (fee.amount == 0 ? "waived" : nil))
            }
            Divider()
            LabeledAmountRow(label: "Total", amount: agreement.total, emphasized: true)
            if agreement.total <= state.session.targetPrice {
                Label("At or below your target", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if isBuyer, agreement.total > state.session.maxBudget {
                Label("Above your max budget", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func sourcesCard(_ state: SessionState, _ agreement: Agreement) -> some View {
        Card(title: "Where each term came from") {
            ForEach(agreement.sourceEventIds, id: \.self) { id in
                if let event = state.event(id: id) {
                    Button {
                        withAnimation { expandedSource = expandedSource == id ? nil : id }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            TranscriptLineView(event: event, compact: expandedSource != id)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func confirmationsCard(_ agreement: Agreement) -> some View {
        Card(title: "Confirmations") {
            confirmationRow(isBuyer ? "You (buyer)" : "Buyer", at: agreement.buyerConfirmedAt)
            confirmationRow(isBuyer ? "Seller" : "You (seller)", at: agreement.sellerConfirmedAt)
        }
    }

    private func confirmationRow(_ who: String, at date: Date?) -> some View {
        HStack {
            Image(systemName: date == nil ? "clock" : "checkmark.circle.fill")
                .foregroundStyle(date == nil ? .orange : .green)
            Text(who)
            Spacer()
            Text(date == nil ? "Waiting…" : "Confirmed \(TimeFormat.clock(date))")
                .foregroundStyle(.secondary).font(.subheadline)
        }
    }

    private func lockedFooter(_ agreement: Agreement) -> some View {
        Card(title: "Locked", tint: .green) {
            Text(isBuyer
                 ? "The seller's terminal can only charge \(Money.format(agreement.total, alwaysShowCents: true)). Any extra charge is blocked until you approve it here."
                 : "Your terminal is locked to \(Money.format(agreement.total, alwaysShowCents: true)).")
                .font(.subheadline)
            if let fp = agreement.fingerprint {
                Text("SHA-256 \(fp)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
            }
            if isBuyer {
                HStack { ProgressView(); Text("Waiting for the seller to charge…").font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }
}
