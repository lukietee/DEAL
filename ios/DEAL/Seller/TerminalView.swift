import SwiftUI

/// S4. Tap to Pay Terminal (simulated). Sand screen:
///   DEAL Terminal / [AGREED TOTAL $34,600.00 · 🔒 Locked to agreement] / ((( Tap to Pay ))) / [+ Add line item]
/// The amount always comes from the agreement and cannot be edited. "Add line item" posts a
/// payment request (agreement lines + the extra) which the backend blocks; the terminal then
/// waits for the buyer. "Tap to Pay" runs a simulated contactless animation, then charges.
struct TerminalView: View {
    var store: SessionStore
    @State private var showAddItem = false
    @State private var tapPhase: TapPhase = .idle

    enum TapPhase: Equatable { case idle, presenting, processing, failed }

    private var isTapping: Bool { tapPhase == .presenting || tapPhase == .processing }

    var body: some View {
        let state = store.state
        let terminal = state.terminalState
        ZStack {
            Palette.sand.ignoresSafeArea()
            if isTapping {
                presentingLayout(state)
                    .transition(.opacity)
            } else {
                standardLayout(state, terminal)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(Palette.ink)
        .font(DealFont.body)
        .animation(.easeInOut(duration: 0.25), value: isTapping)
        .dealKeepAwake()
        .sheet(isPresented: $showAddItem) {
            AddLineItemSheet(prefill: state.isMarketplace ? ("gas fee", "20") : ("protection package", "1200"),
                             agreedTotal: state.terminalAmount) { label, amount in
                Task { await store.addLineItem(label: label, amount: amount) }
            }
        }
    }

    // MARK: Layouts

    private func standardLayout(_ state: SessionState, _ terminal: TerminalState) -> some View {
        VStack(spacing: 16) {
            HStack {
                SellerExitButton()
                Spacer()
                Text("DEAL Terminal").font(DealFont.jakarta(18, .extrabold))
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }

            amountCard(state)

            statusArea(terminal)

            Spacer(minLength: 0)

            Button { showAddItem = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                    Text("Add line item")
                }
                .font(DealFont.jakarta(15, .bold))
                .foregroundStyle(Palette.dark)
                .padding(.horizontal, 22)
                .frame(height: 48)
                .background(Capsule().fill(Palette.surfaceWarm))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add line item")
            .disabled(isWaiting(terminal) || tapPhase != .idle)
            .opacity(isWaiting(terminal) ? 0.45 : 1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    /// Full-screen "Hold card near iPhone" while the simulated read and the charge run.
    private func presentingLayout(_ state: SessionState) -> some View {
        VStack(spacing: 0) {
            Text("DEAL Terminal").font(DealFont.jakarta(18, .extrabold))
                .padding(.top, 16)
            VStack(spacing: 12) {
                Text(Money.format(state.terminalAmount ?? 0, alwaysShowCents: true))
                    .font(DealFont.jakarta(48, .extrabold))
                    .kerning(-2.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                lockChip(state, fill: Palette.surfaceWarm, compact: true)
            }
            .padding(.top, 24)

            Spacer(minLength: 12)
            ContactlessRings(active: true, size: 300, discSize: 120) {
                Image(systemName: tapPhase == .processing ? "hourglass" : "wave.3.right")
                    .font(.system(size: 44, weight: .semibold))
            }
            Spacer(minLength: 12)

            VStack(spacing: 6) {
                Text(tapLabel)
                    .font(DealFont.jakarta(28, .extrabold))
                    .kerning(-0.6)
                Text(tapPhase == .processing ? "Charging exactly the agreed amount"
                                             : "Buyer taps their card or phone on the top edge")
                    .font(DealFont.jakarta(15))
                    .foregroundStyle(Palette.mutedWarm)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }

    // MARK: Pieces

    private func amountCard(_ state: SessionState) -> some View {
        VStack(spacing: 10) {
            Text("AGREED TOTAL")
                .font(DealFont.jakarta(11, .extrabold))
                .kerning(1.5)
                .foregroundStyle(Palette.mutedWarm)
            Text(Money.format(state.terminalAmount ?? 0, alwaysShowCents: true))
                .font(DealFont.jakarta(54, .extrabold))
                .kerning(-2.4)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.default, value: state.terminalAmount)
            Text(state.session.item)
                .font(DealFont.caption)
                .foregroundStyle(Palette.mutedWarm)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            lockChip(state, fill: Palette.surface, compact: false)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(Palette.surfaceWarm))
    }

    private func lockChip(_ state: SessionState, fill: Color, compact: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: compact ? 12 : 13, weight: .bold))
            Text("Locked to agreement")
                .font(DealFont.jakarta(compact ? 13 : 14, compact ? .bold : .extrabold))
            if state.agreement?.fingerprint != nil {
                Text(Fingerprint.short(state.agreement))
                    .font(DealFont.mono(compact ? 13 : 14, .medium))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, compact ? 14 : 16)
        .frame(height: compact ? 36 : 40)
        .background(Capsule().fill(fill))
    }

    private func isWaiting(_ t: TerminalState) -> Bool {
        if case .waitingForBuyer = t { return true }
        return false
    }

    /// The extra line the seller added (last line of the request) and how much it adds.
    private func extra(_ req: PaymentRequest) -> (label: String, amount: Int)? {
        guard let total = store.state.agreement?.total, req.amount > total,
              let line = req.lineItems.last else { return nil }
        return (line.label.prefix(1).uppercased() + line.label.dropFirst(), req.amount - total)
    }

    @ViewBuilder
    private func statusArea(_ terminal: TerminalState) -> some View {
        switch terminal {
        case .waitingForBuyer(let req):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Circle().fill(Palette.amber).frame(width: 12, height: 12)
                        .background(Circle().fill(Palette.amber.opacity(0.25)).frame(width: 22, height: 22))
                    Text("Waiting for buyer approval")
                        .font(DealFont.jakarta(18, .extrabold))
                }
                HStack {
                    Text("Requested").foregroundStyle(Palette.muted)
                    Spacer()
                    Text(Money.format(req.amount, alwaysShowCents: true)).font(DealFont.jakarta(15, .extrabold))
                }
                .font(DealFont.jakarta(15, .semibold))
                if let extra = extra(req) {
                    HStack {
                        Text(extra.label).foregroundStyle(Palette.muted)
                        Spacer()
                        Text("+" + Money.format(extra.amount, alwaysShowCents: true)).font(DealFont.jakarta(15, .extrabold))
                    }
                    .font(DealFont.jakarta(15, .semibold))
                }
                Text("This doesn't match the agreement, so the charge is blocked until the buyer approves it.")
                    .font(DealFont.caption)
                    .lineSpacing(3)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(Palette.surface))

            Spacer(minLength: 0)
            pausedDisc
        case .rejected(let req):
            HStack(spacing: 14) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Palette.red)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Palette.sand))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Buyer rejected the change")
                        .font(DealFont.jakarta(17, .extrabold))
                    Text(rejectedDetail(req))
                        .font(DealFont.jakarta(14))
                        .lineSpacing(2)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(Palette.surface))

            Spacer(minLength: 0)
            tapButton(size: 210, discSize: 152)
        case .approved(let req) where req.amount != store.state.agreement?.total:
            // Shouldn't happen (approval amends the agreement), but never charge an off-agreement amount.
            Text("Approved request doesn't match the agreement total.")
                .font(DealFont.bodyBold)
                .foregroundStyle(Palette.red)
                .multilineTextAlignment(.center)
                .padding(.top, 24)
        case .ready, .approved:
            Spacer(minLength: 0)
            tapButton(size: 236, discSize: 168)
        }
    }

    private func rejectedDetail(_ req: PaymentRequest) -> String {
        let agreed = Money.format(store.state.agreement?.total ?? store.state.terminalAmount ?? 0, alwaysShowCents: true)
        if let extra = extra(req) {
            return "The \(Money.format(extra.amount)) \(extra.label.lowercased()) was removed. Charge the agreed \(agreed) instead."
        }
        return "Charge the agreed \(agreed) instead."
    }

    /// Dashed, disabled terminal while a request waits for the buyer.
    private var pausedDisc: some View {
        ZStack {
            Circle().strokeBorder(Color(hex: 0x9C958A), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            VStack(spacing: 6) {
                Image(systemName: "pause.fill").font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Palette.navInactive)
                Text("Paused").font(DealFont.jakarta(15, .extrabold)).foregroundStyle(Palette.mutedWarm)
            }
            .frame(width: 136, height: 136)
            .background(Circle().fill(Palette.surfaceWarm))
        }
        .frame(width: 180, height: 180)
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity)
    }

    private func tapButton(size: CGFloat, discSize: CGFloat) -> some View {
        Button {
            Task { await runTap() }
        } label: {
            ContactlessRings(active: false, size: size, discSize: discSize) {
                VStack(spacing: 8) {
                    Image(systemName: "wave.3.right")
                        .font(.system(size: discSize * 0.22, weight: .semibold))
                    Text(tapLabel).font(DealFont.jakarta(discSize > 160 ? 20 : 18, .extrabold))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tapLabel)
        .disabled(isTapping || store.isBusy)
        .frame(maxWidth: .infinity)
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

/// White disc inside thin concentric rings; the rings ripple outward while `active`.
private struct ContactlessRings<Center: View>: View {
    var active: Bool
    var size: CGFloat
    var discSize: CGFloat
    @ViewBuilder var center: Center
    @State private var animate = false

    var body: some View {
        ZStack {
            if active {
                ForEach(0..<3) { i in
                    let inset = CGFloat(i) * (size - discSize) / 6
                    Circle()
                        .strokeBorder(Palette.ink.opacity(0.08 + Double(i) * 0.12), lineWidth: i == 2 ? 2 : 1)
                        .padding(inset)
                        .scaleEffect(animate ? 1.06 : 0.94)
                        .opacity(animate ? 0.5 : 1)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true).delay(Double(i) * 0.2),
                                   value: animate)
                }
            } else {
                Circle().strokeBorder(Palette.ink.opacity(0.12), lineWidth: 1)
                Circle().strokeBorder(Palette.ink.opacity(0.22), lineWidth: 1)
                    .padding(size * 0.076)
            }
            center
                .foregroundStyle(Palette.ink)
                .frame(width: discSize, height: discSize)
                .background(Circle().fill(Palette.surface))
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onAppear { animate = active }
        .onChange(of: active) { _, isActive in animate = isActive }
    }
}

/// S4 "+ Add line item" (e.g. "protection package", $1,200). The amount is the extra only;
/// the agreed lines are included automatically.
/// Marketplace sessions pre-fill the demo's "$20 for gas".
struct AddLineItemSheet: View {
    var agreedTotal: Int?
    var onAdd: (String, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var amount: String

    init(prefill: (label: String, dollars: String) = ("protection package", "1200"),
         agreedTotal: Int? = nil,
         onAdd: @escaping (String, Int) -> Void) {
        self.agreedTotal = agreedTotal
        self.onAdd = onAdd
        _label = State(initialValue: prefill.label)
        _amount = State(initialValue: prefill.dollars)
    }

    private var trimmedLabel: String { label.trimmingCharacters(in: .whitespaces) }
    private var cents: Int? { Money.parseDollars(amount) }
    private var canAdd: Bool { !trimmedLabel.isEmpty && cents != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Capsule().fill(Color(hex: 0xB5AEA3)).frame(width: 40, height: 5)
                    .frame(maxWidth: .infinity)
                ZStack {
                    Text("Add line item").font(DealFont.jakarta(18, .extrabold))
                        .accessibilityAddTraits(.isHeader)
                    HStack {
                        Button("Cancel") { dismiss() }
                            .font(DealFont.jakarta(15, .bold))
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .background(Capsule().fill(Color(hex: 0xE4DFD7)))
                            .buttonStyle(.plain)
                        Spacer()
                    }
                }

                fieldLabel("Description")
                TextField("Label", text: $label)
                    .font(DealFont.jakarta(17, .bold))
                    .padding(.horizontal, 22)
                    .frame(height: 58)
                    .background(Capsule().fill(Palette.surface))
                    .accessibilityIdentifier("Label")

                fieldLabel("Amount")
                HStack(spacing: 4) {
                    Text("$").font(DealFont.jakarta(30, .extrabold)).foregroundStyle(Color(hex: 0x6E6E6E))
                    TextField("Amount", text: $amount)
                        .font(DealFont.jakarta(34, .extrabold))
                        .kerning(-1)
                        .dealKeyboard(.decimal)
                        .fixedSize()
                }
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, minHeight: 76)
                .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(Palette.surface))

                if let agreedTotal {
                    summary(agreedTotal)
                }

                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(Palette.amber).frame(width: 9, height: 9).padding(.top, 6)
                    Text("This isn't in the agreement. The charge stays blocked until the buyer approves it on their phone.")
                        .font(DealFont.jakarta(14))
                        .lineSpacing(3)
                        .foregroundStyle(Color(hex: 0x3B3832))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    if let cents {
                        onAdd(trimmedLabel, cents)
                        dismiss()
                    }
                } label: {
                    Text("Send to buyer for approval")
                        .font(DealFont.jakarta(17, .extrabold))
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(Capsule().fill(Palette.surface))
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
                .opacity(canAdd ? 1 : 0.5)
                // UI tests (and older docs) call this button "Add".
                .accessibilityIdentifier("Add")
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 34)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.fraction(0.82), .large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(40)
        .presentationBackground(Palette.surfaceWarm)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(DealFont.jakarta(13, .bold))
            .foregroundStyle(Palette.mutedWarm)
            .padding(.leading, 6)
            .padding(.bottom, -8)
    }

    private func summary(_ agreed: Int) -> some View {
        let extra = cents ?? 0
        return VStack(spacing: 0) {
            HStack {
                Text("Agreed total")
                Spacer()
                Text(Money.format(agreed, alwaysShowCents: true))
            }
            .font(DealFont.jakarta(15))
            .foregroundStyle(Palette.mutedWarm)
            .padding(.vertical, 12)
            Rectangle().fill(Color(hex: 0xE4DFD7)).frame(height: 1)
            HStack {
                Text(trimmedLabel.isEmpty ? "New line" : trimmedLabel.prefix(1).uppercased() + trimmedLabel.dropFirst())
                Spacer()
                Text("+" + Money.format(extra, alwaysShowCents: true))
            }
            .font(DealFont.jakarta(15, .semibold))
            .padding(.vertical, 12)
            Rectangle().fill(Color(hex: 0xE4DFD7)).frame(height: 1)
            HStack {
                Text("Would request")
                Spacer()
                Text(Money.format(agreed + extra, alwaysShowCents: true)).foregroundStyle(Palette.liveRed)
            }
            .font(DealFont.jakarta(17, .extrabold))
            .padding(.vertical, 13)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
    }
}
