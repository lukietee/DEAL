import SwiftUI
import UniformTypeIdentifiers

/// B7. Purchase History: item, final price, savings vs asking, date. Taps open Deal Detail.
struct PurchaseHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [Session] = []
    @State private var loaded = false
    @State private var loadError: String?
    @State private var query = ""

    private var purchases: [Session] { PurchaseHistory.purchases(sessions) }

    private var filtered: [Session] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return purchases }
        return purchases.filter {
            $0.item.localizedCaseInsensitiveContains(q) || $0.category.displayName.localizedCaseInsensitiveContains(q)
        }
    }

    /// Purchases grouped by month ("October", or "October 2025" outside the current year).
    private var months: [(title: String, sessions: [Session])] {
        var groups: [(title: String, sessions: [Session])] = []
        for s in filtered {
            let title = Self.monthTitle(s.dealDate)
            if groups.last?.title == title { groups[groups.count - 1].sessions.append(s) }
            else { groups.append((title, [s])) }
        }
        return groups
    }

    var body: some View {
        ScrollView {
            HeroScaffold(heroBottomPadding: 76) {
                VStack(spacing: 20) {
                    HStack {
                        CircleIconButton(systemName: "chevron.left") { dismiss() }
                            .accessibilityLabel("Back")
                        Spacer()
                    }
                    Text("Purchase history")
                        .font(DealFont.jakarta(34, .extrabold))
                        .kerning(-1)
                        .frame(maxWidth: .infinity)
                }
            } content: {
                VStack(alignment: .leading, spacing: 18) {
                    searchField
                        .padding(.top, -29)
                        .padding(.horizontal, 28)
                    if let loadError {
                        Text(loadError).font(DealFont.caption).foregroundStyle(Palette.red)
                    }
                    if !purchases.isEmpty {
                        let totals = PurchaseHistory.totals(sessions)
                        HStack(spacing: 10) {
                            HistoryTile(value: Money.format(totals.spent), label: "Spent")
                            HistoryTile(value: Money.format(totals.saved), label: "Saved", fill: Palette.sand, labelColor: Palette.mutedWarm)
                            HistoryTile(value: Money.format(totals.blocked), label: "Blocked", valueColor: Palette.red)
                        }
                    }
                    ForEach(months, id: \.title) { month in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(month.title).font(DealFont.jakarta(22, .extrabold)).kerning(-0.4)
                            VStack(spacing: 0) {
                                ForEach(month.sessions) { session in
                                    NavigationLink(value: BuyerRoute.deal(session)) {
                                        PurchaseRow(session: session)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("historyRow-\(session.id)")
                                    if session.id != month.sessions.last?.id { LedgerDivider() }
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 18)
                            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
                        }
                    }
                    if loaded, loadError == nil {
                        if purchases.isEmpty {
                            SurfaceCard(padding: 20) {
                                Text("No purchases yet").font(DealFont.jakarta(16, .extrabold))
                                Text("Deals you pay for with DEAL show up here.")
                                    .font(DealFont.jakarta(14)).foregroundStyle(Palette.muted)
                            }
                        } else if filtered.isEmpty {
                            Text("No deals match “\(query)”.")
                                .font(DealFont.jakarta(14)).foregroundStyle(Palette.muted)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .buyerHeroUnderlay()
        .dealPage()
        .overlay { if !loaded { ProgressView() } }
        .navigationTitle("Purchase History")
        .buyerHiddenNavBar()
        .refreshable { await load() }
        .task { await load() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            TextField("Search your deals", text: $query)
                .font(DealFont.body)
                .autocorrectionDisabled()
                .submitLabel(.search)
            Image(systemName: query.isEmpty ? "magnifyingglass" : "xmark")
                .font(.system(size: 17, weight: .bold))
                .frame(width: 46, height: 46)
                .background(Circle().fill(Palette.sand))
                .onTapGesture { query = "" }
                .accessibilityHidden(query.isEmpty)
                .accessibilityLabel("Clear search")
        }
        .padding(.leading, 22)
        .padding(.trailing, 6)
        .frame(height: 58)
        .background(Capsule().fill(Palette.surface))
        .shadow(color: .black.opacity(0.12), radius: 9, y: 6)
    }

    static func monthTitle(_ date: Date?) -> String {
        guard let date else { return "Earlier" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        f.dateFormat = sameYear ? "LLLL" : "LLLL yyyy"
        return f.string(from: date)
    }

    private func load() async {
        defer { loaded = true }
        do {
            sessions = try await model.api.listSessions()
            loadError = nil
        } catch {
            loadError = "Couldn't load purchases (\(error.localizedDescription))"
        }
    }
}

/// Compact three-up stat tile used on B7.
private struct HistoryTile: View {
    var value: String
    var label: String
    var fill: Color = Palette.surface
    var valueColor: Color = Palette.ink
    var labelColor: Color = Palette.muted

    var body: some View {
        VStack(spacing: 6) {
            Text(value)
                .font(DealFont.jakarta(21, .extrabold))
                .kerning(-0.4)
                .foregroundStyle(valueColor)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label.uppercased())
                .font(DealFont.jakarta(11, .bold)).kerning(1.3)
                .foregroundStyle(labelColor)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(fill))
    }
}

/// B7 Deal Detail: offer timeline, key cues, agreement, receipt, Export Dispute Pack.
struct DealDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The history row (has `final_price` / `savings`); full state is fetched from `GET /sessions/:id`.
    var session: Session

    @State private var state: SessionState?
    @State private var loadError: String?
    @State private var pack: DisputePackFile?
    @State private var packError: String?
    @State private var showPack = false

    var body: some View {
        ScrollView {
            HeroScaffold(heroBottomPadding: 68) {
                header(state)
            } content: {
                VStack(alignment: .leading, spacing: 14) {
                    if let loadError {
                        Text(loadError).font(DealFont.caption).foregroundStyle(Palette.red)
                    }
                    if let state {
                        timelineCard(state)
                        cuesCard(state)
                        if let agreement = state.agreement { agreementCard(state, agreement) }
                        if !state.refusedCharges.isEmpty { blockedCard(state) }
                        if let receipt = state.receipt { receiptCard(state, receipt) }
                        exportSection
                    } else if loadError == nil {
                        ProgressView("Loading deal…").frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(.top, 24)
                .padding(.bottom, 12)
            }
        }
        .buyerHeroUnderlay()
        .dealPage()
        .navigationTitle("Deal Detail")
        .buyerHiddenNavBar()
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $showPack) {
            if let pack {
                DisputePackSheet(pack: pack, session: state?.session ?? session, state: state)
            }
        }
    }

    // MARK: Header

    private func header(_ state: SessionState?) -> some View {
        let s = state?.session ?? session
        let paid = state?.receipt?.amount ?? session.finalPrice ?? state?.agreement?.total
        let saved = paid.map { s.askingPrice - $0 } ?? session.savingsVsAsking
        let blocked = state?.blockedTotal ?? session.blockedTotal ?? 0
        let date = TimeFormat.full(state?.receipt?.createdAt ?? session.dealDate)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                CircleIconButton(systemName: "chevron.left", size: 44) { dismiss() }
                    .accessibilityLabel("Back")
                Spacer()
                CircleIconButton(systemName: "square.and.arrow.up", size: 44) { showPack = true }
                    .disabled(pack == nil)
                    .opacity(pack == nil ? 0.5 : 1)
                    .accessibilityLabel("Export dispute pack")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(date.isEmpty ? s.category.displayName : "\(s.category.displayName) · \(date)")
                    .font(DealFont.jakarta(13, .semibold))
                    .foregroundStyle(Palette.mutedWarm)
                Text(s.item)
                .font(DealFont.jakarta(26, .extrabold))
                .kerning(-0.5)
                Text(Money.format(paid, placeholder: "—", alwaysShowCents: true))
                    .font(DealFont.jakarta(52, .extrabold))
                    .kerning(-2.3)
                    .lineLimit(1).minimumScaleFactor(0.5)
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("Asked")
                        Text(Money.format(s.askingPrice)).strikethrough()
                    }
                    .font(DealFont.jakarta(13, .semibold))
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Capsule().fill(Palette.ink.opacity(0.12)))
                    if let saved, saved > 0 {
                        Text("saved \(Money.format(saved))")
                            .font(DealFont.jakarta(13, .extrabold))
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(Capsule().fill(Palette.surface))
                    }
                    if blocked > 0 {
                        Text("blocked \(Money.format(blocked))")
                            .font(DealFont.jakarta(13, .extrabold))
                            .foregroundStyle(Palette.liveRed)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(Capsule().fill(Color(hex: 0xE5483B).opacity(0.22)))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 4)
            }
        }
    }

    // MARK: Offer timeline

    private func cardTitle(_ title: String) -> some View {
        Text(title).font(DealFont.jakarta(22, .extrabold)).kerning(-0.4)
    }

    private func timelineCard(_ state: SessionState) -> some View {
        let points = state.offerTimeline
        let agreedTotal = state.agreement?.total
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                cardTitle("Offer timeline")
                    // Deal Detail's UI test looks this heading up by its old uppercase card title.
                    .accessibilityIdentifier("Offer timeline".uppercased())
                Spacer()
                HStack(spacing: 12) {
                    legend(Palette.faint, "Seller")
                    legend(Palette.ink, "You")
                }
            }
            if points.isEmpty {
                Text("No offers were recorded.").font(DealFont.jakarta(14)).foregroundStyle(Palette.muted)
            } else {
                if points.count > 1 {
                    OfferChart(points: points, target: state.session.targetPrice)
                        .frame(height: 124)
                        .padding(.bottom, 4)
                }
                VStack(spacing: 0) {
                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        let mine = point.by == .buyer
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Circle().fill(mine ? Palette.ink : Palette.faint).frame(width: 9, height: 9)
                                    .frame(width: 14)
                                HStack(spacing: 5) {
                                    Text(mine ? "You" : "Seller").fontWeight(.bold)
                                        .foregroundStyle(mine ? Palette.ink : Palette.muted)
                                    Text(Money.format(point.amount)).fontWeight(.heavy)
                                    if index == points.count - 1, point.amount == agreedTotal {
                                        Text("agreed")
                                            .font(DealFont.jakarta(11, .bold))
                                            .padding(.horizontal, 8).frame(height: 20)
                                            .background(Capsule().fill(Palette.sand))
                                    }
                                }
                                .font(DealFont.jakarta(14))
                                Spacer(minLength: 4)
                                if index == 0 {
                                    Text("opening").font(DealFont.jakarta(12)).foregroundStyle(Palette.muted)
                                } else {
                                    let delta = point.amount - points[index - 1].amount
                                    if delta != 0 {
                                        Text(Money.formatDelta(delta))
                                            .font(DealFont.jakarta(12, .bold))
                                            .foregroundStyle(mine ? Palette.ink : Palette.muted)
                                    }
                                }
                                Text(Self.shortClock(point.timestamp))
                                    .font(DealFont.mono(11)).foregroundStyle(Palette.muted)
                            }
                            Text("“\(point.text)”")
                                .font(DealFont.caption).foregroundStyle(Palette.muted)
                                .lineLimit(1)
                                .padding(.leading, 22)
                        }
                        .padding(.vertical, 10)
                        .overlay(alignment: .top) { LedgerDivider() }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(DealFont.jakarta(12, .semibold)).foregroundStyle(Palette.muted)
        }
    }

    static func shortClock(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm"
        return f.string(from: date)
    }

    // MARK: Key cues

    private func cuesCard(_ state: SessionState) -> some View {
        let cues = state.keyCues
        return VStack(alignment: .leading, spacing: 10) {
            cardTitle("Key cues")
            if cues.isEmpty {
                Text("No cues were shown.").font(DealFont.jakarta(14)).foregroundStyle(Palette.muted)
            }
            ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    StatusDot(color: cue.status.color, size: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cue.text).font(DealFont.jakarta(15, .bold))
                        if let detail = cue.detail, !detail.isEmpty {
                            Text(detail).font(DealFont.caption).foregroundStyle(Palette.muted)
                        }
                        if let tactic = cue.tactic, !tactic.isEmpty, tactic != "none" {
                            Text("Tactic: \(tactic.humanizedIdentifier)").font(DealFont.jakarta(12)).foregroundStyle(Palette.muted)
                        }
                    }
                    Spacer()
                    Text(Self.shortClock(cue.timestamp)).font(DealFont.mono(11)).foregroundStyle(Palette.muted)
                }
                .padding(.top, index == 0 ? 0 : 10)
                .overlay(alignment: .top) { if index > 0 { LedgerDivider() } }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
    }

    // MARK: Agreement

    private func agreementCard(_ state: SessionState, _ agreement: Agreement) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                cardTitle("Agreement")
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: agreement.isLocked ? "lock.fill" : "doc.text").font(.system(size: 11, weight: .bold))
                    Text(Fingerprint.short(agreement)).font(DealFont.mono(12, .semibold))
                    if agreement.version > 1 { Text("v\(agreement.version)").font(DealFont.jakarta(12, .bold)) }
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(Capsule().fill(Palette.sand))
            }
            .padding(.bottom, 6)
            if agreement.fingerprintValid == false {
                Label("Fingerprint mismatch", systemImage: "exclamationmark.shield.fill")
                    .font(DealFont.jakarta(12, .bold)).foregroundStyle(Palette.red)
                    .padding(.bottom, 6)
            }
            compactRow((agreement.items.first ?? state.session.item).capitalizedFirst, value: Money.format(agreement.price))
            ForEach(agreement.items.dropFirst(), id: \.self) { item in
                LedgerDivider()
                compactRow(item.capitalizedFirst, value: "Included")
            }
            ForEach(agreement.fees, id: \.self) { fee in
                LedgerDivider()
                compactRow(fee.label.capitalizedFirst, note: fee.note ?? (fee.amount == 0 ? "waived" : nil),
                           value: Money.format(fee.amount))
            }
            LedgerDivider()
            HStack {
                Text("Total")
                Spacer()
                Text(Money.format(agreement.total))
            }
            .font(DealFont.jakarta(17, .extrabold))
            .padding(.vertical, 13)
            LedgerDivider()
            mutedRow("Buyer confirmed", TimeFormat.full(agreement.buyerConfirmedAt).nonEmpty ?? "—")
                .padding(.top, 11).padding(.bottom, 4)
            mutedRow("Seller confirmed", TimeFormat.full(agreement.sellerConfirmedAt).nonEmpty ?? "—")
                .padding(.top, 4).padding(.bottom, 8)
            ForEach(Array(agreement.amendments.enumerated()), id: \.offset) { _, amendment in
                Text("Amended \(TimeFormat.clock(amendment.at)): \(Money.format(amendment.previousTotal, placeholder: "—")) → \(Money.format(amendment.newTotal, placeholder: "—"))")
                    .font(DealFont.jakarta(12, .semibold)).foregroundStyle(Palette.liveRed)
                    .padding(.bottom, 6)
            }
            if let fp = agreement.fingerprint {
                Text("SHA-256 \(fp)")
                    .font(DealFont.mono(11)).foregroundStyle(Palette.muted)
                    .lineLimit(2).textSelection(.enabled)
                    .padding(.bottom, 4)
            }
        }
        .padding(.top, 20).padding(.horizontal, 20).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
    }

    private func compactRow(_ label: String, note: String? = nil, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(DealFont.jakarta(15, .semibold))
            if let note, !note.isEmpty {
                Text(note).font(DealFont.jakarta(13)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            Text(value).font(DealFont.jakarta(15, .extrabold))
        }
        .padding(.vertical, 11)
    }

    private func mutedRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(DealFont.jakarta(14))
        .foregroundStyle(Palette.muted)
    }

    // MARK: Blocked charges

    private func blockedCard(_ state: SessionState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(state.refusedCharges) { request in
                let extra = ChargeMath.extraAmount(request: request, agreement: state.agreement)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        HStack(spacing: 8) {
                            Circle().fill(Color(hex: 0xE5483B)).frame(width: 8, height: 8)
                            Text("CHARGE BLOCKED").font(DealFont.jakarta(12, .extrabold)).kerning(1.4)
                                .foregroundStyle(Palette.liveRed)
                        }
                        Spacer()
                        Text("Rejected by you · \(TimeFormat.clock(request.decidedAt))")
                            .font(DealFont.jakarta(12)).foregroundStyle(Palette.mutedWarm)
                    }
                    ForEach(ChargeMath.extraLineItems(request: request, agreement: state.agreement), id: \.self) { item in
                        HStack {
                            Text(item.label.capitalizedFirst)
                            Spacer()
                            Text(Money.formatDelta(item.amount)).foregroundStyle(Palette.liveRed)
                        }
                        .font(DealFont.jakarta(17, .extrabold))
                    }
                    HStack {
                        Text("Requested total")
                        Spacer()
                        Text(Money.format(request.amount))
                        if extra > 0 {
                            Text("(\(Money.formatDelta(extra)))").foregroundStyle(Palette.liveRed)
                        }
                    }
                    .font(DealFont.jakarta(14))
                    .foregroundStyle(Palette.mutedWarm)
                    if let explanation = request.mismatchExplanation, !explanation.isEmpty {
                        Text(explanation)
                            .font(DealFont.jakarta(14))
                            .foregroundStyle(Palette.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.sand))
    }

    // MARK: Receipt

    private func receiptCard(_ state: SessionState, _ receipt: Receipt) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("Receipt").padding(.bottom, 2)
            Text(state.receiptSummary)
                .font(DealFont.jakarta(13, .semibold)).foregroundStyle(Palette.muted)
                .padding(.bottom, 6)
            receiptRow("Amount", Money.format(receipt.amount, alwaysShowCents: true), bold: true)
            LedgerDivider()
            receiptRow("Merchant", receipt.merchant ?? "Seller")
            LedgerDivider()
            receiptRow("Time", TimeFormat.full(receipt.createdAt))
            LedgerDivider()
            receiptRow("Status", receipt.status.capitalizedFirst)
            LedgerDivider()
            receiptRow("Payment ID", receipt.stripePaymentId, mono: true)
            LedgerDivider()
            receiptRow("Agreement", Fingerprint.short(receipt.agreementFingerprint), mono: true)
            Text(receipt.mock ? "Simulated payment (backend mock mode)." : "Stripe test mode · Visa test card. No real money moved.")
                .font(DealFont.jakarta(12)).foregroundStyle(Palette.muted)
                .padding(.top, 6)
        }
        .padding(.top, 20).padding(.horizontal, 20).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
    }

    private func receiptRow(_ label: String, _ value: String, mono: Bool = false, bold: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).font(DealFont.jakarta(14, .semibold)).foregroundStyle(Palette.muted)
            Spacer()
            Text(value)
                .font(mono ? DealFont.mono(13) : DealFont.jakarta(14, bold ? .extrabold : .bold))
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.vertical, 11)
    }

    // MARK: Dispute pack

    @ViewBuilder
    private var exportSection: some View {
        if pack != nil {
            Button { showPack = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .bold))
                        .accessibilityHidden(true)
                    Text("Export Dispute Pack")
                }
            }
            .buttonStyle(PillButtonStyle(kind: .sand, height: 58))
            .accessibilityIdentifier("exportDisputePack")
            Text("JSON with the transcript, agreement, fingerprint and receipt")
                .font(DealFont.jakarta(12)).foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.top, -4)
        } else if let packError {
            SurfaceCard(padding: 20) {
                Text(packError).font(DealFont.caption).foregroundStyle(Palette.red)
                Button("Retry") { Task { await loadPack() } }
                    .buttonStyle(PillButtonStyle(kind: .sand, height: 44, fullWidth: false))
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Preparing dispute pack…").font(DealFont.caption).foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Loading

    private func load() async {
        async let packTask: Void = loadPack()
        do {
            state = try await model.api.sessionState(id: session.id)
            loadError = nil
        } catch {
            loadError = "Couldn't load this deal (\(error.localizedDescription))"
        }
        await packTask
    }

    private func loadPack() async {
        do {
            let data = try await model.api.disputePack(sessionID: session.id)
            pack = try DisputePackFile.write(data, sessionID: session.id)
            packError = nil
        } catch {
            packError = "Couldn't build the dispute pack (\(error.localizedDescription))"
        }
    }
}

/// Offers converging over time: seller dots grey, buyer dots ink, dashed target line.
private struct OfferChart: View {
    var points: [OfferPoint]
    var target: Int

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let values = points.map(\.amount) + (target > 0 ? [target] : [])
            let lo = Double(values.min() ?? 0), hi = Double(values.max() ?? 1)
            let span = max(hi - lo, 1)
            let top: CGFloat = 14, bottom: CGFloat = h - 24
            let x: (Int) -> CGFloat = { i in 8 + (w - 16) * CGFloat(i) / CGFloat(max(points.count - 1, 1)) }
            let y: (Int) -> CGFloat = { v in top + (bottom - top) * CGFloat((hi - Double(v)) / span) }
            ZStack(alignment: .topLeading) {
                if target > 0 {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y(target)))
                        p.addLine(to: CGPoint(x: w, y: y(target)))
                    }
                    .stroke(Palette.ink, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    Text("Target \(Money.format(target))")
                        .font(DealFont.jakarta(11, .semibold)).foregroundStyle(Palette.muted)
                        .fixedSize()
                        .position(x: w - 46, y: min(y(target) + 14, h - 6))
                }
                Path { p in
                    for (i, pt) in points.enumerated() {
                        let c = CGPoint(x: x(i), y: y(pt.amount))
                        if i == 0 { p.move(to: c) } else { p.addLine(to: c) }
                    }
                }
                .stroke(Color(hex: 0xC7C7C7), lineWidth: 2)
                ForEach(Array(points.enumerated()), id: \.element.id) { i, pt in
                    let last = i == points.count - 1
                    Circle()
                        .fill(pt.by == .buyer ? Palette.ink : Palette.faint)
                        .overlay(Circle().stroke(Palette.surface, lineWidth: last ? 2.5 : 0))
                        .frame(width: last ? 14 : 11, height: last ? 14 : 11)
                        .position(x: x(i), y: y(pt.amount))
                }
                if let first = points.first {
                    Text(Money.format(first.amount))
                        .font(DealFont.jakarta(11, .semibold)).foregroundStyle(Palette.muted)
                        .fixedSize()
                        .offset(x: x(0) + 10, y: max(0, y(first.amount) - 16))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(points.count > 1
            ? "Offers move from \(Money.format(points.first!.amount)) to \(Money.format(points.last!.amount)) over \(points.count) moves"
            : "")
    }
}

/// B7 dispute pack sheet: the JSON file, what it contains, and Copy / Save to Files / More.
private struct DisputePackSheet: View {
    @Environment(\.dismiss) private var dismiss
    var pack: DisputePackFile
    var session: Session
    var state: SessionState?
    @State private var copied = false
    @State private var exporting = false

    private var fileSize: String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: pack.url.path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// What the pack contains, from this deal's state.
    private var contents: [String] {
        guard let state else { return ["Agreement, transcript, payment requests and receipt"] }
        var items: [String] = []
        if !state.events.isEmpty { items.append("Full transcript with timestamps") }
        if let a = state.agreement {
            items.append(a.isLocked ? "Locked agreement and both confirmations" : "Agreement draft and confirmations")
        }
        let blocked = state.blockedTotal
        if !state.refusedCharges.isEmpty {
            items.append(blocked > 0 ? "Blocked \(Money.format(blocked)) charge and your rejection" : "Blocked charge and your rejection")
        }
        if state.receipt != nil { items.append("Payment receipt") }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetGrabber().frame(maxWidth: .infinity).padding(.top, 12)
            VStack(alignment: .leading, spacing: 4) {
                Text("Export dispute pack").font(DealFont.jakarta(28, .extrabold)).kerning(-0.8)
                Text("Evidence for your bank or card issuer if the charge is ever disputed.")
                    .font(DealFont.jakarta(14)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 4)

            HStack(spacing: 14) {
                Text("JSON")
                    .font(DealFont.mono(10, .semibold))
                    .frame(width: 48, height: 56, alignment: .bottom)
                    .padding(.bottom, 8)
                    .frame(width: 48, height: 56)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface))
                VStack(alignment: .leading, spacing: 3) {
                    Text(pack.url.lastPathComponent)
                        .font(DealFont.mono(13, .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(fileSize) · signed with \(Fingerprint.short(state?.agreement))")
                        .font(DealFont.caption).foregroundStyle(Palette.mutedWarm)
                    Text(pack.summary)
                        .font(DealFont.jakarta(11)).foregroundStyle(Palette.mutedWarm)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 14).padding(.leading, 14).padding(.trailing, 18)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.sand))

            VStack(alignment: .leading, spacing: 12) {
                ForEach(contents, id: \.self) { line in
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Palette.sand))
                        Text(line).font(DealFont.jakarta(15, .semibold))
                    }
                }
            }
            .padding(.vertical, 16).padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))

            HStack(spacing: 10) {
                Button {
                    if let data = try? Data(contentsOf: pack.url) {
                        LedgerPasteboard.copy(String(decoding: data, as: UTF8.self))
                        copied = true
                    }
                } label: {
                    actionTile(copied ? "checkmark" : "doc.on.doc", copied ? "Copied" : "Copy")
                }
                Button { exporting = true } label: {
                    actionTile("folder", "Save to Files")
                }
                ShareLink(item: pack.url, preview: SharePreview(pack.url.lastPathComponent, image: Image(systemName: "doc.text"))) {
                    actionTile("ellipsis", "More")
                }
            }
            .buttonStyle(.plain)

            Button("Close") { dismiss() }
                .buttonStyle(PillButtonStyle(kind: .surface))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Palette.ink)
        .background(Palette.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(40)
        .fileExporter(isPresented: $exporting,
                      document: JSONFileDocument(url: pack.url),
                      contentType: .json,
                      defaultFilename: pack.url.lastPathComponent) { _ in }
    }

    private func actionTile(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).frame(height: 24)
            Text(label).font(DealFont.jakarta(13, .bold))
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Palette.surface))
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// The dispute pack JSON as a document for "Save to Files".
private struct JSONFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(url: URL) { data = (try? Data(contentsOf: url)) ?? Data() }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// The `GET /sessions/:id/dispute-pack` JSON, pretty-printed into a temp file for ShareLink.
struct DisputePackFile: Equatable {
    var url: URL
    var summary: String

    static func write(_ data: Data, sessionID: String) throws -> DisputePackFile {
        var output = data
        var summary = "\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)) JSON"
        if let object = try? JSONSerialization.jsonObject(with: data) {
            if let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                output = pretty
            }
            if let dict = object as? [String: Any] {
                var parts: [String] = []
                if let format = dict["format"] as? String { parts.append(format) }
                if let fp = dict["fingerprint"] as? [String: Any], let valid = fp["valid"] as? Bool {
                    parts.append(valid ? "fingerprint valid" : "fingerprint INVALID")
                }
                if let excerpts = dict["transcript_excerpts"] as? [Any] { parts.append("\(excerpts.count) transcript lines") }
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(output.count), countStyle: .file))
                summary = parts.joined(separator: " · ")
            }
        }
        let safeID = sessionID.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DEAL-dispute-pack-\(safeID).json")
        try output.write(to: url, options: .atomic)
        return DisputePackFile(url: url, summary: summary)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
