import SwiftUI

/// B4 (buyer) and S3 (seller): the same agreement on both phones.
/// Final price, included items, fees, total; each term links to its source transcript line
/// (buyer only — the transcript is private to the buyer); open questions; Confirm + the other
/// side's status; "Agreement locked" badge with the short fingerprint after both confirm.
struct AgreementReviewView: View {
    var store: SessionStore
    var onKeepNegotiating: (() -> Void)? = nil
    @State private var expandedSource: String?
    @State private var copied = false

    private var isBuyer: Bool { store.role == .buyer }

    var body: some View {
        let state = store.state
        ScrollView {
            if let agreement = state.agreement {
                HeroScaffold(heroBottomPadding: agreement.isLocked ? 72 : 64) {
                    if agreement.isLocked {
                        lockedHero(state.session, agreement)
                    } else {
                        draftHero(state.session, agreement)
                    }
                } content: {
                    VStack(alignment: .leading, spacing: 14) {
                        if agreement.isLocked { terminalNote(agreement, locked: true) }
                        termsCard(state, agreement)
                        if !agreement.isLocked, !agreement.openQuestions.isEmpty {
                            openQuestions(agreement)
                        }
                        if isBuyer, !agreement.isLocked, !agreement.sourceEventIds.isEmpty {
                            sourcesCard(state, agreement)
                        }
                        confirmations(agreement)
                        if !agreement.isLocked, !isBuyer { terminalNote(agreement, locked: false) }
                        if agreement.isLocked, let fp = agreement.fingerprint { fingerprintCard(fp) }
                    }
                    .padding(.top, 24)
                }
            } else {
                ProgressView("Drafting agreement…").padding(.top, 80).frame(maxWidth: .infinity)
            }
        }
        .buyerHeroUnderlay()
        .dealPage()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let agreement = state.agreement {
                if !agreement.isConfirmed(by: store.role) {
                    LedgerDock {
                        Button {
                            Task {
                                await store.confirmAgreement()
                                Platform.haptic(.success)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                if store.isBusy {
                                    ProgressView().tint(Palette.ink)
                                } else {
                                    Image(systemName: "checkmark").font(.system(size: 17, weight: .bold))
                                        .accessibilityHidden(true)
                                }
                                Text("Confirm \(Money.format(agreement.total))")
                            }
                        }
                        .buttonStyle(PillButtonStyle(kind: .sand, height: 58))
                        .disabled(store.isBusy)
                        if let onKeepNegotiating, isBuyer {
                            Button("Keep negotiating", action: onKeepNegotiating)
                                .font(DealFont.button)
                                .foregroundStyle(Palette.muted)
                                .frame(height: 44)
                        }
                    }
                } else if isBuyer, agreement.isLocked {
                    LedgerDock {
                        HStack(spacing: 8) {
                            Circle().fill(Palette.amber).frame(width: 8, height: 8)
                            Text("Waiting for the seller to charge")
                                .font(DealFont.jakarta(14, .semibold))
                                .foregroundStyle(Palette.muted)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                } else if !agreement.isLocked {
                    LedgerDock {
                        HStack(spacing: 8) {
                            Circle().fill(Palette.amber).frame(width: 8, height: 8)
                            Text("Waiting for the \(isBuyer ? "seller" : "buyer") to confirm")
                                .font(DealFont.jakarta(14, .semibold))
                                .foregroundStyle(Palette.muted)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }
        }
        .navigationTitle(isBuyer ? "Agreement Review" : "Agreement")
        .dealInlineTitle()
        .buyerClearNavBar()
    }

    // MARK: Hero

    private func draftHero(_ session: Session, _ agreement: Agreement) -> some View {
        let otherConfirmed = isBuyer ? agreement.sellerConfirmedAt != nil : agreement.buyerConfirmedAt != nil
        let mineConfirmed = agreement.isConfirmed(by: store.role)
        return VStack(spacing: 6) {
            Group {
                if otherConfirmed, !mineConfirmed {
                    Text("\(isBuyer ? "Seller" : "Buyer") confirmed · your turn")
                        .font(DealFont.jakarta(12, .extrabold))
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(Capsule().fill(Palette.surface))
                } else {
                    Text("Draft · needs both confirmations")
                        .font(DealFont.jakarta(12, .bold))
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(Capsule().fill(Palette.ink.opacity(0.12)))
                }
            }
            .padding(.bottom, 4)
            Text(session.item)
                .font(DealFont.jakarta(16, .bold))
                .foregroundStyle(Palette.inkSoft)
                .multilineTextAlignment(.center)
            Text(Money.format(agreement.total))
                .font(DealFont.jakarta(56, .extrabold))
                .kerning(-2.5)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text("agreed total")
                .font(DealFont.caption)
                .foregroundStyle(Palette.mutedWarm)
            badges(agreement)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func lockedHero(_ session: Session, _ agreement: Agreement) -> some View {
        let sealed = [agreement.buyerConfirmedAt, agreement.sellerConfirmedAt].compactMap { $0 }.max()
        return VStack(spacing: 14) {
            ZStack {
                Circle().strokeBorder(Palette.ink.opacity(0.45), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                Circle().strokeBorder(Palette.ink.opacity(0.25), lineWidth: 1).padding(10)
                Image(systemName: "lock.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .frame(width: 84, height: 84)
                    .background(Circle().fill(Palette.surface))
                    .background(Circle().fill(Palette.green.opacity(0.25)).padding(-8))
            }
            .frame(width: 132, height: 132)
            HStack(spacing: 8) {
                Circle().fill(Palette.green).frame(width: 8, height: 8)
                Text("AGREEMENT LOCKED").font(DealFont.jakarta(12, .extrabold)).kerning(1.9)
            }
            Text(Money.format(agreement.total))
                .font(DealFont.jakarta(56, .extrabold))
                .kerning(-2.5)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(sealed == nil ? session.item : "\(session.item) · sealed \(TimeFormat.clock(sealed))")
                .font(DealFont.jakarta(14))
                .foregroundStyle(Palette.mutedWarm)
                .multilineTextAlignment(.center)
            Text(Fingerprint.short(agreement))
                .font(DealFont.mono(15, .semibold))
                .kerning(0.6)
                .padding(.horizontal, 18).frame(height: 40)
                .background(Capsule().fill(Palette.surface))
            badges(agreement)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func badges(_ agreement: Agreement) -> some View {
        if agreement.fingerprintValid == false || agreement.version > 1 {
            HStack(spacing: 8) {
                if agreement.fingerprintValid == false {
                    Label("Fingerprint mismatch", systemImage: "exclamationmark.shield.fill")
                        .font(DealFont.jakarta(12, .bold)).foregroundStyle(Palette.red)
                }
                if agreement.version > 1 {
                    Text("v\(agreement.version)").font(DealFont.jakarta(12, .bold)).foregroundStyle(Palette.mutedWarm)
                }
            }
        }
    }

    // MARK: Terms

    private func termsCard(_ state: SessionState, _ agreement: Agreement) -> some View {
        LedgerCard {
            LedgerRow(label: (agreement.items.first ?? state.session.item).capitalizedFirst,
                      value: Money.format(agreement.price))
            ForEach(agreement.items.dropFirst(), id: \.self) { item in
                LedgerDivider()
                LedgerRow(label: item.capitalizedFirst, value: "Included")
            }
            ForEach(agreement.fees, id: \.self) { fee in
                LedgerDivider()
                LedgerRow(label: fee.label.capitalizedFirst, note: fee.note ?? (fee.amount == 0 ? "waived" : nil),
                          value: Money.format(fee.amount))
            }
            LedgerDivider()
            LedgerRow(label: "Total", value: Money.format(agreement.total), emphasized: true)
            if agreement.total <= state.session.targetPrice {
                Label("At or below your target", systemImage: "checkmark.seal.fill")
                    .font(DealFont.jakarta(13, .semibold)).foregroundStyle(Palette.greenText)
                    .padding(.bottom, 14)
            } else if isBuyer, agreement.total > state.session.maxBudget {
                Label("Above your max budget", systemImage: "exclamationmark.triangle.fill")
                    .font(DealFont.jakarta(13, .semibold)).foregroundStyle(Palette.red)
                    .padding(.bottom, 14)
            }
        }
    }

    private func openQuestions(_ agreement: Agreement) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(Palette.amber).frame(width: 10, height: 10).padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                let n = agreement.openQuestions.count
                Text("\(n) open question\(n == 1 ? "" : "s")").font(DealFont.jakarta(15, .extrabold))
                ForEach(agreement.openQuestions, id: \.self) { q in
                    Text(q).font(DealFont.jakarta(14)).foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16).padding(.horizontal, 20)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(hex: 0xD9D9D9)))
    }

    private func sourcesCard(_ state: SessionState, _ agreement: Agreement) -> some View {
        LedgerCard {
            Text("WHERE EACH TERM CAME FROM")
                .font(DealFont.jakarta(11, .extrabold)).kerning(1.3)
                .foregroundStyle(Palette.muted)
                .padding(.top, 14).padding(.bottom, 4)
            let events = agreement.sourceEventIds.compactMap { state.event(id: $0) }
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                if index > 0 { LedgerDivider() }
                Button {
                    withAnimation { expandedSource = expandedSource == event.id ? nil : event.id }
                } label: {
                    sourceLine(event, expanded: expandedSource == event.id)
                }
                .buttonStyle(.plain)
            }
            Color.clear.frame(height: 6)
        }
    }

    private func sourceLine(_ event: DealEvent, expanded: Bool) -> some View {
        let who = event.speaker == .buyer ? "You" : event.speaker.displayName
        let time = TimeFormat.clock(event.timestamp)
        let head = Text(time.isEmpty ? who : "\(who) · \(time)").fontWeight(.bold).foregroundColor(Palette.ink)
        return Text("\(head)  “\(event.text)”")
            .font(DealFont.caption)
            .foregroundStyle(Palette.muted)
            .lineLimit(expanded ? nil : 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
    }

    // MARK: Confirmations

    private func confirmations(_ agreement: Agreement) -> some View {
        HStack(spacing: 12) {
            confirmationTile(isBuyer ? "You" : "Buyer", at: agreement.buyerConfirmedAt, mine: isBuyer,
                             otherConfirmed: agreement.sellerConfirmedAt != nil)
            confirmationTile(isBuyer ? "Seller" : "You", at: agreement.sellerConfirmedAt, mine: !isBuyer,
                             otherConfirmed: agreement.buyerConfirmedAt != nil)
        }
    }

    private func confirmationTile(_ who: String, at date: Date?, mine: Bool, otherConfirmed: Bool) -> some View {
        let needed = mine && date == nil && otherConfirmed
        let status: String = if let date { TimeFormat.clock(date) } else if needed { "needed" } else if mine { "not yet" } else { "waiting" }
        return VStack(spacing: 6) {
            if date != nil {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .heavy))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Palette.sand))
            } else {
                Circle()
                    .strokeBorder(needed ? Palette.ink : Palette.faint, style: StrokeStyle(lineWidth: 2.5, dash: [4, 3]))
                    .frame(width: 26, height: 26)
            }
            Text("\(who) · \(status)").font(DealFont.jakarta(13, needed ? .extrabold : .bold))
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Palette.ink, lineWidth: needed ? 2 : 0)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: Locked

    private func terminalNote(_ agreement: Agreement, locked: Bool) -> some View {
        let amount = Text(Money.format(agreement.total, alwaysShowCents: true)).fontWeight(.bold).foregroundColor(Palette.ink)
        let text: Text = if !locked {
            Text("Once you confirm, your terminal can only charge \(amount). Anything extra needs the buyer's approval.")
        } else if isBuyer {
            Text("The seller's terminal can only charge \(amount). Any extra charge is blocked until you approve it.")
        } else {
            Text("Your terminal is locked to \(amount).")
        }
        return HStack(spacing: 12) {
            Image(systemName: locked ? "lock.shield.fill" : "creditcard.fill")
                .font(.system(size: 22, weight: .semibold))
            text
                .font(DealFont.jakarta(14))
                .foregroundStyle(Palette.dark)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 18).padding(.horizontal, 20)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.sand))
    }

    private func fingerprintCard(_ fp: String) -> some View {
        let hex = fp.hasPrefix("sha256:") ? String(fp.dropFirst(7)) : fp
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SHA-256 FINGERPRINT")
                    .font(DealFont.jakarta(11, .extrabold)).kerning(1.3)
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    LedgerPasteboard.copy(hex)
                    copied = true
                }
                .font(DealFont.jakarta(13, .bold))
                .padding(.horizontal, 14).frame(height: 34)
                .background(Capsule().fill(Palette.sand))
                .buttonStyle(.plain)
            }
            Text(hex)
                .font(DealFont.mono(13))
                .lineSpacing(5)
                .foregroundStyle(Palette.inkSoft)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 16).padding(.horizontal, 20)
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Palette.grabber, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        )
    }
}

// MARK: - Shared pieces for B4 / B5 / B6 / B7 (S3 / S5)

/// White bottom action area with rounded top corners, pinned above the home indicator.
struct LedgerDock<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 4) { content }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                    .fill(Palette.surface)
                    .shadow(color: .black.opacity(0.06), radius: 10, y: -2)
                    .ignoresSafeArea(edges: .bottom)
            )
    }
}

/// White card holding divider-separated label/value rows.
struct LedgerCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 20)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
    }
}

struct LedgerDivider: View {
    var body: some View { Rectangle().fill(Palette.divider).frame(height: 1) }
}

/// "Vehicle price ........ $34,600" with an optional muted note ("waived").
struct LedgerRow: View {
    var label: String
    var note: String? = nil
    var value: String
    var emphasized = false
    var valueColor: Color = Palette.ink

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label).font(DealFont.jakarta(emphasized ? 18 : 16, emphasized ? .extrabold : .semibold))
                if let note, !note.isEmpty {
                    Text(note).font(DealFont.jakarta(13, .semibold)).foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(DealFont.jakarta(emphasized ? 18 : 16, .extrabold))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, emphasized ? 15 : 13)
    }
}

enum LedgerPasteboard {
    static func copy(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
