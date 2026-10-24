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

    var body: some View {
        let state = store.state
        let agreement = state.agreement
        let extra = ChargeMath.extraAmount(request: request, agreement: agreement)
        let extras = ChargeMath.extraLineItems(request: request, agreement: agreement)

        VStack(spacing: 0) {
            banner(extra: extra)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    comparison(agreement: agreement, extras: extras)
                    if let quote = contradictingLine(state) {
                        Card(title: "You agreed", tint: .orange) {
                            Text("“\(quote.text)”").font(.body.italic())
                            if let ts = quote.time {
                                Text("\(quote.speaker) · \(TimeFormat.clock(ts))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let explanation = request.mismatchExplanation, !explanation.isEmpty {
                        Card(title: "Why it was blocked") {
                            Label(explanation, systemImage: "sparkles").font(.subheadline)
                        }
                    }
                }
                .padding()
            }
            actions
        }
        .confirmationDialog("Approve the extra \(Money.format(max(extra, 0)))? The agreement will be amended and re-fingerprinted.",
                            isPresented: $confirmApprove, titleVisibility: .visible) {
            Button("Approve change", role: .destructive) { decide(.approve) }
            Button("Cancel", role: .cancel) {}
        }
        .interactiveDismissDisabled()
    }

    private func banner(extra: Int) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "hand.raised.fill").font(.system(size: 36))
            Text(extra > 0 ? "Charge blocked: \(Money.format(extra)) more than agreed"
                           : "Charge blocked: doesn't match the agreement")
                .font(.title2.weight(.heavy))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal)
        .background(Color.red.gradient)
    }

    private func comparison(agreement: Agreement?, extras: [LineItem]) -> some View {
        let extraLabels = Set(extras.map { $0.label.lowercased() })
        return HStack(alignment: .top, spacing: 12) {
            Card(title: "Agreed") {
                Text(Money.format(request.mismatch?.agreedTotal ?? agreement?.total ?? 0))
                    .font(.title2.weight(.bold).monospacedDigit())
                ForEach(Array((agreement.map { SessionState.lines(for: $0) } ?? []).enumerated()), id: \.offset) { _, li in
                    lineRow(li, highlighted: false)
                }
            }
            Card(title: "Requested", tint: .red) {
                Text(Money.format(request.mismatch?.requestedTotal ?? request.amount))
                    .font(.title2.weight(.bold).monospacedDigit())
                ForEach(Array(request.lineItems.enumerated()), id: \.offset) { _, li in
                    lineRow(li, highlighted: extraLabels.contains(li.label.lowercased()))
                }
            }
        }
    }

    private func lineRow(_ li: LineItem, highlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(li.label.capitalizedFirst).lineLimit(2)
            Spacer(minLength: 4)
            Text(Money.format(li.amount)).monospacedDigit()
        }
        .font(.caption.weight(highlighted ? .bold : .regular))
        .foregroundStyle(highlighted ? .red : .primary)
        .padding(highlighted ? 4 : 0)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Color.red.opacity(0.15) : .clear))
    }

    private struct Quote { var text: String; var speaker: String; var time: Date? }

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

    private var actions: some View {
        VStack(spacing: 10) {
            Button { decide(.reject) } label: {
                HStack {
                    if deciding { ProgressView().tint(.white) }
                    Text("Reject")
                }
            }
            .buttonStyle(PrimaryButtonStyle(tint: .red))
            .keyboardShortcut(.defaultAction)
            Button("Approve change") { confirmApprove = true }
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .disabled(deciding)
        .padding()
        .background(.bar)
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
