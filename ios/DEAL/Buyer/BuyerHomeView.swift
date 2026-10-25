import SwiftUI

/// B1. Home: Start listening (no setup: the backend works out the product and prices from the
/// conversation), Set up with a listing (B2), the active session (if one is running), recent
/// conversations, and totals (amount spent, extra charges blocked).
struct BuyerHomeView: View {
    @Environment(AppModel.self) private var model
    @Binding var path: [BuyerRoute]
    /// `nil` = resume this phone's session; a `Session` = re-attach to one from the backend.
    var onResume: (Session?) -> Void

    @State private var sessions: [Session] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var showSettings = false
    @State private var startingListening = false
    @State private var startError: String?

    private var conversations: [Session] { PurchaseHistory.conversations(sessions) }

    var body: some View {
        ScrollView {
            HeroScaffold(heroBottomPadding: 60) {
                hero
            } content: {
                listenButton
                    .padding(.top, -29)
                    .padding(.trailing, 24)
                setUpButton
                if let startError {
                    Text(startError).font(DealFont.caption).foregroundStyle(Palette.red)
                }
                activeSessionCard
                totals
                recent
            }
        }
        .buyerHeroUnderlay()
        .dealPage()
        .refreshable { await load() }
        .task { await load() }
        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .buyerHiddenNavBar()
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                CircleIconButton(systemName: "chevron.left") { model.exitToModePicker() }
                    .accessibilityLabel("Exit")
                Spacer()
                Chip(text: "Buyer", eyebrow: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Hello,").font(DealFont.jakarta(22, .medium))
                Text("Your deals").font(DealFont.title).kerning(-1)
            }
        }
    }

    /// Primary action: a big ink pill that overlaps the hero's corner notch. Starts a listening
    /// session right away, with no item or prices.
    private var listenButton: some View {
        Button { Task { await startListening() } } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start listening").font(DealFont.jakarta(19, .extrabold))
                    Text("No setup. DEAL works out the item and price.")
                        .font(DealFont.jakarta(12, .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                ZStack {
                    Circle().fill(Palette.surface)
                    if startingListening {
                        ProgressView().tint(Palette.ink)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Palette.ink)
                    }
                }
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(.leading, 24)
            .padding(.trailing, 7)
            .frame(height: 66)
            .background(Capsule().fill(Palette.ink))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(startingListening)
        .accessibilityLabel("Start listening")
        .accessibilityIdentifier("startListening")
    }

    /// Secondary: the original set-up flow (B2: listing import, item, prices).
    /// Keeps the `startNegotiation` identifier the UI tests tap.
    private var setUpButton: some View {
        Button { path.append(.newNegotiation) } label: {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 15, weight: .bold))
                    .accessibilityHidden(true)
                Text("Set up with a listing").font(DealFont.jakarta(15, .bold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.mutedWarm)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .frame(height: 50)
            .background(Capsule().fill(Palette.surface))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 24)
        .accessibilityLabel("Set up with a listing")
        .accessibilityIdentifier("startNegotiation")
    }

    /// `POST /sessions {auto: true}` -> B3. The live session view starts the mic.
    private func startListening() async {
        startingListening = true
        defer { startingListening = false }
        do {
            let session = try await model.api.createSession(CreateSessionBody(style: NegotiationStyle.firm.rawValue, auto: true))
            startError = nil
            let store = model.makeStore(role: .buyer, session: session)
            store.autoStartMic = true
        } catch {
            startError = "Couldn't start listening (\(error.localizedDescription))"
        }
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

    private var hasActiveSession: Bool {
        if let store = model.activeStore, store.role == .buyer, store.state.buyerPhase != .receipt { return true }
        return PurchaseHistory.resumable(sessions) != nil
    }

    private func sessionCard(_ session: Session, offer: Int?, phase: String, resume: @escaping () -> Void) -> some View {
        Button(action: resume) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(phase == "LIVE" ? Palette.liveDot : Palette.amber).frame(width: 7, height: 7)
                        Text(phase == "LIVE" ? "LIVE NOW" : phase == "LOCKED" ? "LOCKED" : "AGREEMENT REVIEW")
                            .font(DealFont.jakarta(11, .bold))
                            .kerning(1.3)
                            .foregroundStyle(phase == "LIVE" ? Palette.liveRed : Palette.mutedWarm)
                    }
                    Text(session.isDetecting ? "Listening…" : session.displayItem)
                        .font(DealFont.cardTitle)
                        .lineLimit(1)
                    Text(session.targetPrice.map { "Offer \(Money.format(offer, placeholder: "—")) · Target \(Money.format($0))" }
                         ?? "Offer \(Money.format(offer, placeholder: "—"))")
                        .font(DealFont.caption)
                        .foregroundStyle(Palette.mutedWarm)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Resume")
                    .font(DealFont.button)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(Capsule().fill(Palette.surface))
            }
            .padding(.vertical, 18)
            .padding(.leading, 20)
            .padding(.trailing, 18)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.sand))
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
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

    @ViewBuilder
    private var totals: some View {
        let totals = PurchaseHistory.totals(sessions)
        if !hasActiveSession {
            SectionHeader(title: "Totals")
        }
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        LazyVGrid(columns: columns, spacing: 12) {
            StatTile(value: Money.format(totals.spent), label: "Spent", height: 100)
                .accessibilityIdentifier("totalSpent")
            StatTile(value: Money.format(totals.blocked), label: "Blocked", valueColor: Palette.red, height: 100)
                .accessibilityIdentifier("totalBlocked")
            StatTile(value: "\(totals.count)", label: totals.count == 1 ? "Purchase" : "Purchases", height: 100)
            StatTile(value: Money.format(totals.saved), label: "Saved", height: 100)
        }
    }

    // MARK: Recent conversations

    @ViewBuilder
    private var recent: some View {
        SectionHeader(title: "Recent") {
            Button { path.append(.history) } label: {
                Text(conversations.isEmpty ? "History" : "See all")
                    .font(DealFont.jakarta(14, .bold))
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(Capsule().fill(Palette.sand))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("purchaseHistory")
        }
        if let loadError {
            Text(loadError).font(DealFont.caption).foregroundStyle(Palette.red)
        }
        if conversations.isEmpty {
            if loading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
            } else if loadError == nil {
                SurfaceCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No conversations yet").font(DealFont.jakarta(16, .extrabold))
                        Text("Tap Start listening. Every conversation shows up here with a summary.")
                            .font(DealFont.jakarta(14))
                            .foregroundStyle(Palette.muted)
                    }
                }
            }
        } else {
            let recent = Array(conversations.prefix(3))
            VStack(spacing: 0) {
                ForEach(recent) { session in
                    Button { open(session) } label: {
                        PurchaseRow(session: session)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("recentRow-\(session.id)")
                    if session.id != recent.last?.id {
                        Rectangle().fill(Palette.divider).frame(height: 1)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
        }
    }

    /// Live rows resume the session; everything else opens Deal Detail.
    private func open(_ session: Session) {
        if session.historyOutcome.isLive {
            onResume(model.activeStore?.session.id == session.id ? nil : session)
        } else {
            path.append(.deal(session))
        }
    }

    // MARK: Tab bar

    /// Bottom nav from the design. Every item maps to an existing destination: Home (here),
    /// Deals (B7), + (B2) and Profile (Settings, the same sheet the mode picker opens).
    /// The design's "Alerts" tab is omitted: charge alerts present themselves over the session.
    private var tabBar: some View {
        HStack(spacing: 0) {
            tabItem("house.fill", label: "Home", current: true) {}
            tabItem("square.stack.fill", label: "Deals") { path.append(.history) }
            tabItem("plus", label: "New negotiation") { path.append(.newNegotiation) }
            tabItem("person.crop.circle", label: "Profile") { showSettings = true }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                .fill(Palette.surface)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func tabItem(_ symbol: String, label: String, current: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(current ? Palette.ink : Palette.navInactive)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            sessions = try await model.api.listSessions()
            loadError = nil
        } catch {
            loadError = "Couldn't load your conversations (\(error.localizedDescription))"
        }
    }
}

/// One conversation: item (or "Untitled conversation"), date, an outcome chip ("Paid · $520",
/// "Deal · $200", "No deal", "Live", "Ended") and, for purchases, savings vs asking. Used on B1 and B7.
struct PurchaseRow: View {
    var session: Session

    var body: some View {
        let outcome = session.historyOutcome
        HStack(alignment: .center, spacing: 12) {
            IconBadge(systemName: session.auto && !session.isPurchase && session.isDetecting ? "waveform" : session.category.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayItem).font(DealFont.bodyBold).lineLimit(1)
                subtitle
                    .font(DealFont.caption)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                OutcomeChip(outcome: outcome)
                if case .paid = outcome, let saved = session.savingsVsAsking, saved > 0 {
                    Text("saved \(Money.format(saved))").font(DealFont.caption).foregroundStyle(Palette.muted)
                } else if case .paid = outcome, let saved = session.savingsVsAsking, saved < 0 {
                    Text("\(Money.format(-saved)) over asking").font(DealFont.caption).foregroundStyle(Palette.red)
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// "Oct 24 · $1,200 blocked", "Oct 12 · Pawn Shop" or "Oct 25 · Listening".
    private var subtitle: Text {
        let date = PurchaseRow.shortDate(session.dealDate)
        let prefix = date.isEmpty ? "" : "\(date) · "
        if let blocked = session.blockedTotal, blocked > 0 {
            let blockedText = Text("\(Money.format(blocked)) blocked").foregroundColor(Palette.red).fontWeight(.semibold)
            return Text("\(prefix)\(blockedText)")
        }
        if session.isDetecting { return Text(prefix + (session.isEnded ? "Product not detected" : "Listening")) }
        return Text(prefix + session.category.displayName)
    }

    static func shortDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

/// History outcome capsule: ink for paid, sand for deals, a red dot for live.
struct OutcomeChip: View {
    var outcome: HistoryOutcome
    var large = false

    var body: some View {
        let (fill, fg): (Color, Color) = switch outcome {
        case .paid: (Palette.ink, .white)
        case .deal: (Palette.sand, Palette.ink)
        case .live: (Palette.liveDot.opacity(0.16), Palette.liveRed)
        case .noDeal, .ended: (Palette.ink.opacity(0.08), Palette.muted)
        }
        HStack(spacing: 5) {
            if outcome.isLive { Circle().fill(Palette.liveDot).frame(width: 6, height: 6) }
            Text(outcome.label)
                .font(DealFont.jakarta(large ? 14 : 12, .extrabold))
                .lineLimit(1)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, large ? 14 : 10)
        .frame(height: large ? 32 : 26)
        .background(Capsule().fill(fill))
    }
}

extension View {
    /// Hides the navigation bar on screens that draw their own hero header (B1, B7).
    @ViewBuilder
    func buyerHiddenNavBar() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    /// Sand behind the status bar / navigation bar so the hero reaches the top edge.
    func buyerHeroUnderlay() -> some View {
        self.background(alignment: .top) {
            Palette.sand.frame(height: 220).ignoresSafeArea(edges: .top)
        }
    }

    /// Lets the sand hero show through the navigation bar (B4, B5, B6).
    @ViewBuilder
    func buyerClearNavBar() -> some View {
        #if os(iOS)
        self.toolbarBackground(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}
