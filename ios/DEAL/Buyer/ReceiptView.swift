import SwiftUI

/// B6 (buyer) and S5 (seller): amount, merchant, time, Stripe test payment ID,
/// agreement fingerprint, and the summary "Asked $38,000, paid $34,600, blocked $1,200".
struct ReceiptView: View {
    @Environment(AppModel.self) private var model
    var store: SessionStore
    @State private var appeared = false

    var body: some View {
        let state = store.state
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.green)
                    .scaleEffect(appeared ? 1 : 0.4)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(duration: 0.5, bounce: 0.4), value: appeared)

                Text(Money.format(state.receipt?.amount ?? state.agreement?.total ?? 0, alwaysShowCents: true))
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                Text("Payment complete").font(.headline).foregroundStyle(.secondary)

                if store.role == .buyer {
                    Text(state.receiptSummary)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Color.green.opacity(0.12)))
                }

                if let receipt = state.receipt {
                    Card(title: "Receipt") {
                        row("Item", state.session.item)
                        row("Merchant", receipt.merchant ?? "Seller")
                        row("Time", TimeFormat.full(receipt.createdAt))
                        row("Status", receipt.status.capitalizedFirst)
                        row("Payment ID", receipt.stripePaymentId, mono: true)
                        row("Agreement", Fingerprint.short(receipt.agreementFingerprint), mono: true)
                        if receipt.mock {
                            Text("Simulated payment (backend mock mode).").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Stripe test mode · Visa test card. No real money moved.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                // Buyer: back to B1 Home (the deal is now in Purchase History). Seller: mode picker.
                Button("Done") {
                    if store.role == .buyer { model.endSession() } else { model.exitToModePicker() }
                }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding()
        }
        .navigationTitle("Receipt")
        .dealInlineTitle()
        .onAppear {
            appeared = true
            Platform.haptic(.success)
            if store.role == .buyer { model.glasses.clear() }
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(mono ? .subheadline.monospaced() : .subheadline)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
