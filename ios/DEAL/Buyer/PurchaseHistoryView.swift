import SwiftUI

/// B7. Purchase History: item, final price, savings vs asking, date. Taps open Deal Detail.
struct PurchaseHistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var sessions: [Session] = []
    @State private var loaded = false
    @State private var loadError: String?

    private var purchases: [Session] { PurchaseHistory.purchases(sessions) }

    var body: some View {
        List {
            if let loadError {
                Text(loadError).font(.footnote).foregroundStyle(.red)
            }
            if !purchases.isEmpty {
                let totals = PurchaseHistory.totals(sessions)
                Section {
                    LabeledAmountRow(label: "Amount spent", amount: totals.spent)
                    LabeledAmountRow(label: "Saved vs asking", amount: totals.saved)
                    LabeledAmountRow(label: "Extra charges blocked", amount: totals.blocked)
                }
            }
            Section {
                ForEach(purchases) { session in
                    NavigationLink(value: BuyerRoute.deal(session)) {
                        PurchaseRow(session: session)
                    }
                    .accessibilityIdentifier("historyRow-\(session.id)")
                }
            } footer: {
                if loaded, purchases.isEmpty, loadError == nil {
                    Text("No purchases yet. Deals you pay for with DEAL show up here.")
                }
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .navigationTitle("Purchase History")
        .refreshable { await load() }
        .task { await load() }
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

/// B7 Deal Detail: offer timeline, key cues, agreement, receipt, Export Dispute Pack.
struct DealDetailView: View {
    @Environment(AppModel.self) private var model
    /// The history row (has `final_price` / `savings`); full state is fetched from `GET /sessions/:id`.
    var session: Session

    @State private var state: SessionState?
    @State private var loadError: String?
    @State private var pack: DisputePackFile?
    @State private var packError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let loadError {
                    Text(loadError).font(.footnote).foregroundStyle(.red)
                }
                header(state)
                if let state {
                    timelineCard(state)
                    cuesCard(state)
                    if let agreement = state.agreement { agreementCard(state, agreement) }
                    if !state.refusedCharges.isEmpty { blockedCard(state) }
                    if let receipt = state.receipt { receiptCard(state, receipt) }
                    exportCard
                } else if loadError == nil {
                    ProgressView("Loading deal…").frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding()
        }
        .navigationTitle("Deal Detail")
        .dealInlineTitle()
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: Header

    private func header(_ state: SessionState?) -> some View {
        let s = state?.session ?? session
        let paid = state?.receipt?.amount ?? session.finalPrice ?? state?.agreement?.total
        let saved = paid.map { s.askingPrice - $0 } ?? session.savingsVsAsking
        return VStack(alignment: .leading, spacing: 6) {
            Label(s.item, systemImage: s.category.symbol).font(.title2.weight(.bold))
            Text(Money.format(paid, placeholder: "—", alwaysShowCents: true))
                .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
            HStack(spacing: 8) {
                Text("Asked \(Money.format(s.askingPrice))").foregroundStyle(.secondary)
                if let saved, saved > 0 {
                    Text("saved \(Money.format(saved))")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.18)))
                        .foregroundStyle(.green)
                }
            }
            .font(.subheadline)
            Text(TimeFormat.full(state?.receipt?.createdAt ?? session.dealDate))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Offer timeline

    private func timelineCard(_ state: SessionState) -> some View {
        let points = state.offerTimeline
        return Card(title: "Offer timeline") {
            if points.isEmpty {
                Text("No offers were recorded.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        Circle().fill(point.by == .buyer ? Theme.accent : Color.orange).frame(width: 10, height: 10)
                            .padding(.top, 5)
                        if index < points.count - 1 {
                            Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2).frame(maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(point.by == .buyer ? "You offered" : "Seller offered").font(.subheadline)
                            Text(Money.format(point.amount)).font(.subheadline.weight(.bold).monospacedDigit())
                            if index > 0 {
                                let delta = point.amount - points[index - 1].amount
                                if delta != 0 {
                                    Text(Money.formatDelta(delta))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(delta < 0 ? .green : .red)
                                }
                            }
                            Spacer()
                            Text(TimeFormat.clock(point.timestamp)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("“\(point.text)”").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: Key cues

    private func cuesCard(_ state: SessionState) -> some View {
        let cues = state.keyCues
        return Card(title: "Key cues") {
            if cues.isEmpty {
                Text("No cues were shown.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(cues) { cue in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StatusDot(color: cue.status.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cue.text).font(.subheadline.weight(.semibold))
                        if let detail = cue.detail, !detail.isEmpty {
                            Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if let tactic = cue.tactic, !tactic.isEmpty, tactic != "none" {
                            Text("Tactic: \(tactic.humanizedIdentifier)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(TimeFormat.clock(cue.timestamp)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Agreement

    private func agreementCard(_ state: SessionState, _ agreement: Agreement) -> some View {
        Card(title: "Agreement") {
            HStack {
                Label(agreement.isLocked ? "Locked" : "Draft", systemImage: agreement.isLocked ? "lock.fill" : "doc.text")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(agreement.isLocked ? .green : .secondary)
                Text(Fingerprint.short(agreement)).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                if agreement.version > 1 {
                    Text("v\(agreement.version)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if agreement.fingerprintValid == false {
                    Label("Mismatch", systemImage: "exclamationmark.shield.fill").font(.caption).foregroundStyle(.red)
                }
            }
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
            Divider()
            detailRow("Buyer confirmed", TimeFormat.full(agreement.buyerConfirmedAt).nonEmpty ?? "—")
            detailRow("Seller confirmed", TimeFormat.full(agreement.sellerConfirmedAt).nonEmpty ?? "—")
            ForEach(Array(agreement.amendments.enumerated()), id: \.offset) { _, amendment in
                Text("Amended \(TimeFormat.clock(amendment.at)): \(Money.format(amendment.previousTotal, placeholder: "—")) → \(Money.format(amendment.newTotal, placeholder: "—"))")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let fp = agreement.fingerprint {
                Text("SHA-256 \(fp)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
            }
        }
    }

    // MARK: Blocked charges

    private func blockedCard(_ state: SessionState) -> some View {
        Card(title: "Charges blocked", tint: .red) {
            ForEach(state.refusedCharges) { request in
                let extra = ChargeMath.extraAmount(request: request, agreement: state.agreement)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Requested \(Money.format(request.amount))").font(.subheadline.weight(.semibold))
                        Spacer()
                        if extra > 0 {
                            Text(Money.formatDelta(extra)).font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(.red)
                        }
                    }
                    ForEach(ChargeMath.extraLineItems(request: request, agreement: state.agreement), id: \.self) { item in
                        LabeledAmountRow(label: item.label.capitalizedFirst, amount: item.amount)
                    }
                    if let explanation = request.mismatchExplanation, !explanation.isEmpty {
                        Text(explanation).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Rejected by you \(TimeFormat.clock(request.decidedAt))").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Receipt

    private func receiptCard(_ state: SessionState, _ receipt: Receipt) -> some View {
        Card(title: "Receipt") {
            Text(state.receiptSummary).font(.subheadline.weight(.semibold))
            detailRow("Amount", Money.format(receipt.amount, alwaysShowCents: true))
            detailRow("Merchant", receipt.merchant ?? "Seller")
            detailRow("Time", TimeFormat.full(receipt.createdAt))
            detailRow("Status", receipt.status.capitalizedFirst)
            detailRow("Payment ID", receipt.stripePaymentId, mono: true)
            detailRow("Agreement", Fingerprint.short(receipt.agreementFingerprint), mono: true)
            Text(receipt.mock ? "Simulated payment (backend mock mode)." : "Stripe test mode · Visa test card. No real money moved.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Dispute pack

    private var exportCard: some View {
        Card(title: "Dispute pack") {
            Text("Agreement, fingerprint, both confirmations, the transcript lines behind each term and any blocked charge, payment requests and the receipt, as JSON.")
                .font(.caption).foregroundStyle(.secondary)
            if let pack {
                ShareLink(item: pack.url, preview: SharePreview(pack.url.lastPathComponent, image: Image(systemName: "doc.text"))) {
                    Label("Export Dispute Pack", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("exportDisputePack")
                Text(pack.summary).font(.caption2.monospaced()).foregroundStyle(.secondary)
            } else if let packError {
                Text(packError).font(.footnote).foregroundStyle(.red)
                Button("Retry") { Task { await loadPack() } }
            } else {
                HStack { ProgressView(); Text("Preparing dispute pack…").font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(mono ? .subheadline.monospaced() : .subheadline)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
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
