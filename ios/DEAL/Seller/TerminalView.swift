import SwiftUI

/// S4. Tap to Pay Terminal (simulated). Layout per Section 4:
///   DEAL Terminal / $34,600.00 / 🔒 Locked to agreement / ((( Tap to Pay ))) / [+ Add line item]
/// The amount always comes from the agreement and cannot be edited. "Add line item" posts a
/// payment request (agreement lines + the extra) which the backend blocks; the terminal then
/// waits for the buyer. "Tap to Pay" runs a simulated contactless animation, then charges.
struct TerminalView: View {
    var store: SessionStore
    @State private var showAddItem = false
    @State private var tapPhase: TapPhase = .idle

    enum TapPhase: Equatable { case idle, presenting, processing, failed }

    var body: some View {
        let state = store.state
        let terminal = state.terminalState
        ZStack {
            LinearGradient(colors: [Color.black, Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Text("DEAL Terminal")
                    .font(.headline).foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 12)

                Spacer()

                Text(Money.format(state.terminalAmount ?? 0, alwaysShowCents: true))
                    .font(.system(size: 54, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.default, value: state.terminalAmount)

                Label("Locked to agreement", systemImage: "lock.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                if state.agreement?.fingerprint != nil {
                    Text(Fingerprint.short(state.agreement)).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.5))
                }

                Spacer()

                statusArea(terminal)

                Spacer()

                Button { showAddItem = true } label: {
                    Label("Add line item", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Capsule().strokeBorder(.white.opacity(0.4)))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .disabled(isWaiting(terminal) || tapPhase != .idle)
                .padding(.bottom, 20)
            }
            .padding()
        }
        .dealKeepAwake()
        .sheet(isPresented: $showAddItem) {
            AddLineItemSheet(prefill: state.isMarketplace ? ("gas fee", "20") : ("protection package", "1200")) { label, amount in
                Task { await store.addLineItem(label: label, amount: amount) }
            }
        }
        .navigationTitle("Terminal")
        .dealInlineTitle()
    }

    private func isWaiting(_ t: TerminalState) -> Bool {
        if case .waitingForBuyer = t { return true }
        return false
    }

    @ViewBuilder
    private func statusArea(_ terminal: TerminalState) -> some View {
        switch terminal {
        case .waitingForBuyer(let req):
            VStack(spacing: 12) {
                ProgressView().tint(.orange).scaleEffect(1.4)
                Text("Waiting for buyer approval")
                    .font(.title3.weight(.bold)).foregroundStyle(.orange)
                Text("Requested \(Money.format(req.amount, alwaysShowCents: true)) doesn't match the agreement. The charge is blocked until the buyer approves it.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
            }
            .padding()
        case .rejected:
            VStack(spacing: 14) {
                Label("Buyer rejected the change", systemImage: "xmark.octagon.fill")
                    .font(.headline).foregroundStyle(.red)
                Text("Charge the agreed amount instead.").font(.footnote).foregroundStyle(.white.opacity(0.7))
                tapButton
            }
        case .approved(let req) where req.amount != store.state.agreement?.total:
            // Shouldn't happen (approval amends the agreement), but never charge an off-agreement amount.
            Text("Approved request doesn't match the agreement total.").foregroundStyle(.red)
        case .ready, .approved:
            tapButton
        }
    }

    private var tapButton: some View {
        Button {
            Task { await runTap() }
        } label: {
            ZStack {
                ContactlessRings(active: tapPhase == .presenting || tapPhase == .processing)
                VStack(spacing: 6) {
                    Image(systemName: tapPhase == .processing ? "hourglass" : "wave.3.right")
                        .font(.system(size: 34, weight: .semibold))
                    Text(tapLabel).font(.headline)
                }
                .foregroundStyle(.white)
            }
            .frame(width: 220, height: 220)
        }
        .buttonStyle(.plain)
        .disabled(tapPhase == .presenting || tapPhase == .processing || store.isBusy)
    }

    private var tapLabel: String {
        switch tapPhase {
        case .idle: "Tap to Pay"
        case .presenting: "Hold card near iPhone"
        case .processing: "Processing…"
        case .failed: "Try again"
        }
    }

    /// Simulated contactless read, then the real backend charge (Stripe test mode or mock).
    private func runTap() async {
        Platform.haptic(.tap)
        tapPhase = .presenting
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        tapPhase = .processing
        let ok = await store.chargeAgreedAmount()
        tapPhase = ok ? .idle : .failed
        Platform.haptic(ok ? .success : .error)
    }
}

private struct ContactlessRings: View {
    var active: Bool
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .strokeBorder(Theme.accent.opacity(active ? 0.8 : 0.35), lineWidth: 3)
                    .scaleEffect(active && animate ? 1.0 + CGFloat(i) * 0.12 : 0.7 + CGFloat(i) * 0.12)
                    .opacity(active && animate ? 0.2 : 1)
                    .animation(active ? .easeOut(duration: 1.0).repeatForever(autoreverses: false).delay(Double(i) * 0.2)
                                      : .default, value: animate)
            }
            Circle().fill(Theme.accent.gradient).frame(width: 150, height: 150)
        }
        .onChange(of: active, initial: true) { _, isActive in animate = isActive }
    }
}

/// S4 "+ Add line item" (e.g. "protection package", $1,200). The amount is the extra only;
/// the agreed lines are included automatically.
/// Marketplace sessions pre-fill the demo's "$20 for gas".
struct AddLineItemSheet: View {
    var onAdd: (String, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var amount: String

    init(prefill: (label: String, dollars: String) = ("protection package", "1200"),
         onAdd: @escaping (String, Int) -> Void) {
        self.onAdd = onAdd
        _label = State(initialValue: prefill.label)
        _amount = State(initialValue: prefill.dollars)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $label)
                    HStack {
                        Text("$").foregroundStyle(.secondary)
                        TextField("Amount", text: $amount).dealKeyboard(.decimal)
                    }
                } footer: {
                    Text("Anything not in the agreement is blocked until the buyer approves it on their phone.")
                }
            }
            .navigationTitle("Add line item")
            .dealInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let cents = Money.parseDollars(amount) {
                            onAdd(label.trimmingCharacters(in: .whitespaces), cents)
                            dismiss()
                        }
                    }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || Money.parseDollars(amount) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
