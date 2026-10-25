import SwiftUI
import PhotosUI

/// B2. New Negotiation: import a Marketplace listing (link or screenshot), category, item,
/// asking/target/max, style, comparables, Start Session.
struct NewNegotiationView: View {
    @Environment(AppModel.self) private var model

    @State private var category: DealCategory = .marketplace
    @State private var item = ""
    @State private var asking = ""
    @State private var target = ""
    @State private var maxBudget = ""
    @State private var style: NegotiationStyle = .firm

    @State private var comparables: [Comparable] = []
    @State private var comparablesError: String?
    @State private var loadingComparables = false
    // "Check market price" (POST /research/preview), used when demo shortcuts are off.
    @State private var marketPreview: ResearchPreview?
    @State private var marketError: String?
    @State private var checkingMarket = false
    @State private var marketGeneration = 0
    @State private var isStarting = false
    @State private var error: String?

    // Import listing
    @State private var listingLink = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var listing: Listing?
    @State private var listingNote: String?
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showTextEntry = false
    @State private var listingText = ""
    /// Bumped by every fill/import so a slow import can't overwrite a newer choice (e.g. Car demo).
    @State private var fillGeneration = 0

    /// Demo shortcuts (Settings): auto-loaded demo listing, Car demo / Use demo values, static comparables.
    private var demo: Bool { model.settings.demoShortcuts }
    private var trimmedItem: String { item.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var askingCents: Int? { Money.parseDollars(asking) }
    private var targetCents: Int? { Money.parseDollars(target) }
    private var maxCents: Int? { Money.parseDollars(maxBudget) }

    private var validationMessage: String? {
        if item.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the item." }
        guard let a = askingCents, let t = targetCents, let m = maxCents else { return "Enter asking, target and max prices." }
        if t > a { return "Target should be at or below the asking price." }
        if m < t { return "Max budget should be at or above the target." }
        return nil
    }

    var body: some View {
        ScrollView {
            HeroScaffold(heroBottomPadding: 76) {
                Text("New negotiation")
                    .font(DealFont.jakarta(34, .extrabold))
                    .kerning(-1)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            } content: {
                itemField
                    .padding(.horizontal, 8)
                    .padding(.top, -29)
                importSection
                categorySection
                numbersSection
                styleSection
                if demo { comparablesSection } else { marketPriceSection }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                Palette.background
                Palette.sand.frame(height: 320)
            }
            .ignoresSafeArea()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { startBar }
        .font(DealFont.body)
        .foregroundStyle(Palette.ink)
        .tint(Palette.ink)
        .navigationTitle("New Negotiation")
        .dealInlineTitle()
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
            ToolbarItemGroup(placement: .dealTrailing) {
                if demo {
                    Button("Car demo") { fillCarDemo() }
                    Button("Use demo values") { Task { await fillMarketplaceDemo() } }
                }
            }
        }
        .toolbarBackground(Palette.sand, for: .navigationBar)
        .task(id: category) { if demo { await loadComparables() } }
        .task { if demo && item.isEmpty && listing == nil { await fillMarketplaceDemo() } }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task { await importScreenshot(newItem) }
        }
    }

    // MARK: Sections

    /// The floating "What are you buying?" field that overlaps the hero's bottom edge.
    private var itemField: some View {
        TextField("What are you buying?", text: $item)
            .font(DealFont.jakarta(17, .bold))
            .padding(.horizontal, 22)
            .frame(height: 58)
            .background(Capsule().fill(Palette.surface).shadow(color: .black.opacity(0.12), radius: 9, y: 6))
            .accessibilityLabel("What are you buying?")
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Category")
            FlowLayout(spacing: 8) {
                ForEach(DealCategory.allCases) { c in
                    let selected = c == category
                    Button { category = c } label: {
                        Text(c.displayName)
                            .font(DealFont.jakarta(15, selected ? .bold : .semibold))
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .background(Capsule().fill(selected ? Palette.sand : Self.chipIdle))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var numbersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Your numbers")
            HStack(spacing: 10) {
                moneyTile("Asking", a11y: "Asking price", text: $asking, fill: Palette.surface)
                moneyTile("Target", a11y: "Target price", text: $target, fill: Palette.sand)
                moneyTile("Max", a11y: "Maximum budget", text: $maxBudget, fill: Palette.surface)
            }
            VStack(alignment: .leading, spacing: 10) {
                if let a = askingCents, let t = targetCents, let m = maxCents, t < a, m >= t {
                    RangeMeter(asking: a, target: t, maxBudget: m)
                }
                Text("Cues stay green at or below target, turn yellow up to your max, red above it.")
                    .font(DealFont.caption)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Palette.surface))
        }
    }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Style")
            HStack(spacing: 4) {
                ForEach(NegotiationStyle.allCases) { s in
                    let selected = s == style
                    Button { style = s } label: {
                        Text(s.displayName)
                            .font(DealFont.jakarta(15, selected ? .bold : .semibold))
                            .foregroundStyle(selected ? Palette.ink : Palette.muted)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Capsule().fill(selected ? Palette.sand : .clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(5)
            .background(Capsule().fill(Palette.surface))
        }
    }

    private var comparablesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Comparable prices") {
                Text("Illustrative").font(DealFont.jakarta(12)).foregroundStyle(Palette.muted)
            }
            VStack(spacing: 0) {
                if loadingComparables {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
                } else if comparables.isEmpty {
                    Text(comparablesError ?? "No comparables for this category.")
                        .font(DealFont.caption).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 14)
                } else {
                    let shown = Array(comparables.prefix(4))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, comp in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(comp.title).font(DealFont.jakarta(15, .bold))
                                if let source = comp.source {
                                    Text(source).font(DealFont.caption).foregroundStyle(Palette.muted)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(Money.format(comp.price)).font(DealFont.jakarta(16, .extrabold))
                        }
                        .padding(.vertical, 13)
                        if index < shown.count - 1 { Rectangle().fill(Palette.divider).frame(height: 1) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
            Text("Illustrative listings for demo purposes.")
                .font(DealFont.jakarta(12)).foregroundStyle(Palette.muted)
                .padding(.horizontal, 6)
        }
    }

    /// B2 "Market price": one web search for what this item really sells for, on demand.
    private var marketPriceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Market price") {
                if marketPreview != nil && !checkingMarket {
                    Button("Check again") { Task { await checkMarketPrice() } }
                        .font(DealFont.jakarta(13, .bold))
                        .buttonStyle(.plain)
                        .disabled(trimmedItem.isEmpty)
                }
            }
            SurfaceCard(padding: 16) {
                if checkingMarket {
                    HStack(spacing: 10) {
                        ProgressView().tint(Palette.ink)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Searching the web…").font(DealFont.jakarta(15, .bold))
                            Text("Comparing prices for \(trimmedItem). This takes about 20 seconds.")
                                .font(DealFont.caption).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                } else if let marketPreview {
                    marketResult(marketPreview)
                } else {
                    Text(trimmedItem.isEmpty
                         ? "Enter what you're buying, then check what it actually sells for."
                         : "See what \(trimmedItem) actually sells for before you start.")
                        .font(DealFont.caption).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await checkMarketPrice() }
                    } label: {
                        Label("Check market price", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(PillButtonStyle(kind: .ink, height: 48))
                    .disabled(trimmedItem.isEmpty)
                    .opacity(trimmedItem.isEmpty ? 0.4 : 1)
                    .padding(.top, 4)
                }
                if let marketError, !checkingMarket {
                    Text(marketError).font(DealFont.caption).foregroundStyle(Palette.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func marketResult(_ preview: ResearchPreview) -> some View {
        if let range = Self.range(preview) {
            VStack(alignment: .leading, spacing: 2) {
                Text("FAIR RANGE")
                    .font(DealFont.jakarta(11, .extrabold)).kerning(1.3)
                    .foregroundStyle(Palette.muted)
                Text(range.low == range.high ? Money.format(range.low) : "\(Money.format(range.low)) – \(Money.format(range.high))")
                    .font(DealFont.jakarta(30, .extrabold)).kerning(-1)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let a = askingCents, a > 0 {
                    Text(a > range.high ? "Asking \(Money.format(a)) is above the range."
                         : a < range.low ? "Asking \(Money.format(a)) is below the range."
                         : "Asking \(Money.format(a)) is within the range.")
                        .font(DealFont.jakarta(13, .semibold))
                        .foregroundStyle(a > range.high ? Palette.red : Palette.greenText)
                }
            }
            .accessibilityElement(children: .combine)
        }
        if let summary = preview.summary, !summary.isEmpty {
            Text(summary)
                .font(DealFont.jakarta(14))
                .foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        if Self.range(preview) == nil && (preview.summary ?? "").isEmpty && preview.sources.isEmpty {
            Text("No prices found for this item. Try a more specific name (brand, model, size).")
                .font(DealFont.caption).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        let shown = Array(preview.sources.prefix(4))
        if !shown.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, source in
                    MarketSourceRow(source: source)
                    if index < shown.count - 1 { Rectangle().fill(Palette.divider).frame(height: 1) }
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.surfaceWarm))
            .padding(.top, 4)
        }
    }

    /// The fair range from `price_low` / `price_high`; a single bound counts as both.
    private static func range(_ p: ResearchPreview) -> (low: Int, high: Int)? {
        switch (p.priceLow, p.priceHigh) {
        case let (l?, h?): (min(l, h), max(l, h))
        case let (l?, nil): (l, l)
        case let (nil, h?): (h, h)
        default: nil
        }
    }

    private var startBar: some View {
        VStack(spacing: 8) {
            if let error {
                Text(error).font(DealFont.caption).foregroundStyle(Palette.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                Task { await start() }
            } label: {
                HStack(spacing: 8) {
                    if isStarting { ProgressView().tint(Palette.ink) }
                    Text("Start Session")
                }
            }
            .buttonStyle(PillButtonStyle(kind: .sand, height: 58))
            .disabled(validationMessage != nil || isStarting)
            .opacity(validationMessage != nil ? 0.55 : 1)
            if let msg = validationMessage {
                Text(msg).font(DealFont.jakarta(12)).foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                .fill(Palette.surface)
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: .black.opacity(0.05), radius: 10, y: -2)
        )
    }

    // MARK: Import listing

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Import listing")
            SurfaceCard(padding: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "link").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.muted)
                    TextField("Paste a Marketplace link", text: $listingLink)
                        .font(DealFont.jakarta(15, .semibold))
                        .dealURLEntry()
                        .onSubmit { Task { await importLink() } }
                        .accessibilityIdentifier("listingLink")
                    PasteButton(payloadType: String.self) { strings in
                        guard let first = strings.first else { return }
                        Task { @MainActor in
                            listingLink = first.trimmingCharacters(in: .whitespacesAndNewlines)
                            await importLink()
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                    .tint(Palette.sand)
                }
                .padding(.leading, 16)
                .padding(.trailing, 5)
                .frame(height: 50)
                .background(Capsule().fill(Palette.surfaceWarm))

                HStack(spacing: 8) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Listing screenshot", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(PillButtonStyle(kind: .sand, height: 44, fullWidth: false))
                    Spacer(minLength: 0)
                    Button {
                        Task { await importLink() }
                    } label: {
                        if isImporting { ProgressView().tint(.white) } else { Text("Import") }
                    }
                    .buttonStyle(PillButtonStyle(kind: .ink, height: 44, fullWidth: false))
                    .disabled(listingLink.trimmingCharacters(in: .whitespaces).isEmpty || isImporting)
                    .opacity(listingLink.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                }
                .padding(.top, 2)

                if showTextEntry {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Paste the listing text: title, price, description…", text: $listingText, axis: .vertical)
                            .font(DealFont.jakarta(15))
                            .lineLimit(3...8)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.surfaceWarm))
                            .accessibilityIdentifier("listingText")
                        HStack(spacing: 8) {
                            PasteButton(payloadType: String.self) { strings in
                                guard let first = strings.first else { return }
                                Task { @MainActor in listingText = first }
                            }
                            .buttonBorderShape(.capsule)
                            .tint(Palette.sand)
                            Spacer(minLength: 0)
                            let empty = listingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            Button {
                                Task { await importText() }
                            } label: {
                                Text("Read listing")
                            }
                            .buttonStyle(PillButtonStyle(kind: .ink, height: 44, fullWidth: false))
                            .disabled(empty || isImporting)
                            .opacity(empty ? 0.4 : 1)
                        }
                    }
                    .padding(.top, 2)
                } else {
                    Button {
                        withAnimation { showTextEntry = true }
                    } label: {
                        Label("Paste listing text instead", systemImage: "text.alignleft")
                            .font(DealFont.jakarta(14, .bold))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .padding(.leading, 4)
                }

                if isImporting {
                    Label("Reading listing…", systemImage: "text.viewfinder")
                        .font(DealFont.caption).foregroundStyle(Palette.muted)
                }
                if let importError {
                    Text(importError).font(DealFont.caption).foregroundStyle(Palette.red)
                }
                if let listing {
                    ListingCard(listing: listing, note: listingNote) { clearListing() }
                        .padding(.top, 4)
                }
            }
            Text("Paste a Facebook Marketplace link, the listing text, or a screenshot. DEAL reads the price and what the seller claims about condition, then checks those claims at the meetup.")
                .font(DealFont.jakarta(12)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
        }
    }

    /// A link goes as `url`; anything else (pasted listing text) goes as `text`.
    private func importLink() async {
        let raw = listingLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let looksLikeURL = raw.lowercased().hasPrefix("http") || raw.contains("facebook.com") || raw.contains("fb.me")
        let ok = await runImport(note: nil) {
            try await model.api.parseListing(url: looksLikeURL ? raw : nil, text: looksLikeURL ? nil : raw)
        }
        // An unreadable link (e.g. a login wall): offer the text box the backend's message points to.
        if !ok && looksLikeURL && !demo { withAnimation { showTextEntry = true } }
    }

    /// "Paste listing text": the listing's words go to the parser as `text`.
    private func importText() async {
        let raw = listingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        await runImport(note: "Read from listing text") {
            try await model.api.parseListing(text: raw)
        }
    }

    private func importScreenshot(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let base64 = ImageEncoding.jpegBase64(from: data) else {
            importError = "Couldn't read that image."
            return
        }
        await runImport(note: "Read from screenshot") {
            try await model.api.parseListing(imageBase64: base64)
        }
    }

    @discardableResult
    private func runImport(note: String?, fallback: Listing? = nil, _ op: () async throws -> Listing) async -> Bool {
        fillGeneration += 1
        let generation = fillGeneration
        isImporting = true
        importError = nil
        defer { if generation == fillGeneration { isImporting = false } }
        do {
            let parsed = try await op()
            guard generation == fillGeneration else { return false }
            apply(parsed, note: note)
            return true
        } catch {
            guard generation == fillGeneration else { return false }
            if let fallback {
                apply(fallback, note: "Offline demo listing (backend couldn't parse: \(error.localizedDescription))")
                return true
            }
            // Real mode: the backend's own message ("Couldn't read that link. Paste the listing text…").
            importError = demo ? "Couldn't import the listing. \(error.localizedDescription)" : error.localizedDescription
            return false
        }
    }

    /// Prefills the form from a listing: Marketplace, item, asking, and target/max defaults.
    private func apply(_ parsed: Listing, note: String?) {
        listing = parsed
        listingNote = note
        category = parsed.isFacebookMarketplace ? .marketplace : (DealCategory(rawValue: parsed.category) ?? .marketplace)
        item = parsed.title
        if parsed.askingPrice > 0 {
            let d = MarketplaceDemo.defaults(asking: parsed.askingPrice)
            asking = Money.editableString(parsed.askingPrice)
            target = Money.editableString(d.target)
            maxBudget = Money.editableString(d.max)
        }
        style = .firm
    }

    private func clearListing() {
        fillGeneration += 1
        listing = nil
        listingNote = nil
        importError = nil
        isImporting = false
    }

    private static let chipIdle = Color(hex: 0xDADADA)

    /// B2 number tile: big centered amount over a small caps label.
    private func moneyTile(_ title: String, a11y: String, text: Binding<String>, fill: Color) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 1) {
                Text("$").foregroundStyle(text.wrappedValue.isEmpty ? Palette.faint : Palette.ink)
                TextField("0", text: text)
                    .dealKeyboard(.decimal)
                    .fixedSize()
                    .accessibilityLabel(a11y)
            }
            .font(DealFont.jakarta(22, .extrabold))
            .kerning(-0.4)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 8)
            Text(title.uppercased())
                .font(DealFont.jakarta(11, .bold))
                .kerning(1.1)
                .foregroundStyle(fill == Palette.sand ? Palette.mutedWarm : Palette.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 104)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(fill))
    }

    /// "Use demo values": the flagship Marketplace bike, through a canned import of the demo link.
    /// Pawn Shop keeps its own demo values.
    private func fillMarketplaceDemo() async {
        if category == .pawnShop {
            clearListing()
            item = "Fender Player Stratocaster (used)"
            asking = "650"; target = "500"; maxBudget = "575"
            style = .firm
            return
        }
        listingLink = MarketplaceDemo.listingURL
        await runImport(note: "Demo listing", fallback: MarketplaceDemo.offlineBike) {
            try await model.api.parseListing(url: MarketplaceDemo.listingURL)
        }
    }

    /// "Car demo": the 2023 Honda Accord scenario (no listing).
    private func fillCarDemo() {
        clearListing()
        listingLink = ""
        category = .car
        item = "2023 Honda Accord EX"
        asking = "38000"; target = "34500"; maxBudget = "36000"
        style = .firm
    }

    private func checkMarketPrice() async {
        let query = trimmedItem
        guard !query.isEmpty else { return }
        marketGeneration += 1
        let generation = marketGeneration
        checkingMarket = true
        marketError = nil
        defer { if generation == marketGeneration { checkingMarket = false } }
        do {
            let preview = try await model.api.researchPreview(item: query, category: category, askingPrice: askingCents)
            guard generation == marketGeneration else { return }
            marketPreview = preview
        } catch {
            guard generation == marketGeneration else { return }
            marketPreview = nil
            marketError = "Couldn't check the market price. \(error.localizedDescription)"
        }
    }

    private func loadComparables() async {
        loadingComparables = true
        defer { loadingComparables = false }
        do {
            comparables = try await model.api.comparables(category: category)
            comparablesError = nil
        } catch {
            comparables = []
            comparablesError = "Couldn't load comparables (\(error.localizedDescription))"
        }
    }

    /// The listing as negotiated: edits to the item name / asking price win over the parsed values.
    private func listingForSession(_ l: Listing) -> Listing {
        var l = l
        let trimmed = item.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { l.title = trimmed }
        if let a = askingCents { l.askingPrice = a }
        return l
    }

    private func start() async {
        guard validationMessage == nil, let a = askingCents, let t = targetCents, let m = maxCents else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            let session = try await model.api.createSession(CreateSessionBody(
                category: category.rawValue, item: item.trimmingCharacters(in: .whitespaces),
                askingPrice: a, targetPrice: t, maxBudget: m, style: style.rawValue,
                listing: listing.map(listingForSession)))
            error = nil
            let store = model.makeStore(role: .buyer, session: session)
            if session.listing == nil, let listing { store.fallbackListing = listingForSession(listing) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One "Market price" source: thumbnail, title, site / note, price. Opens the page on tap.
private struct MarketSourceRow: View {
    var source: ResearchSource
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: source.url), url.scheme?.hasPrefix("http") == true { openURL(url) }
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: source.imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack {
                            Palette.sand
                            Image(systemName: "tag.fill").font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Palette.mutedWarm)
                        }
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title).font(DealFont.jakarta(14, .bold)).lineLimit(2)
                    let detail = [source.host, source.note ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !detail.isEmpty {
                        Text(detail).font(DealFont.jakarta(12)).foregroundStyle(Palette.muted).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let price = source.price {
                    Text(Money.format(price)).font(DealFont.jakarta(15, .extrabold))
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .multilineTextAlignment(.leading)
    }
}

/// B2 "Your numbers" meter: low end … target (green) … max (red) … asking, on one track.
private struct RangeMeter: View {
    var asking: Int
    var target: Int
    var maxBudget: Int

    private static let filled = Color(hex: 0x8C8478)
    private static let track = Color(hex: 0xE0E0E0)
    private static let dangerDot = Color(hex: 0xD93025)

    var body: some View {
        let low = max(0, target - max(asking - target, 1))
        let span = Double(max(asking - low, 1))
        let tPos = min(max(Double(target - low) / span, 0), 1)
        let mPos = min(max(Double(maxBudget - low) / span, 0), 1)
        VStack(spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Self.track)
                    Rectangle().fill(Palette.faint)
                        .frame(width: max(0, w * (mPos - tPos)))
                        .offset(x: w * tPos)
                    UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 5)
                        .fill(Self.filled)
                        .frame(width: w * tPos)
                }
            }
            .frame(height: 10)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    label(Self.short(low), color: Palette.muted).position(x: 18, y: 8)
                    label(Self.short(asking), color: Palette.muted).position(x: w - 18, y: 8)
                    label(Self.short(target), dot: Palette.greenText).position(x: w * tPos, y: 8)
                    label(Self.short(maxBudget), dot: Self.dangerDot).position(x: min(w * mPos, w - 70), y: 8)
                }
            }
            .frame(height: 16)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Target \(Money.format(target)), max \(Money.format(maxBudget)), asking \(Money.format(asking))")
    }

    private func label(_ text: String, color: Color = Palette.ink, dot: Color? = nil) -> some View {
        HStack(spacing: 4) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(text)
        }
        .font(DealFont.jakarta(12, .semibold))
        .foregroundStyle(color)
        .fixedSize()
    }

    /// `$34.5k`, `$31k`, `$650`.
    static func short(_ cents: Int) -> String {
        let dollars = Double(cents) / 100
        guard dollars >= 1000 else { return Money.format(cents) }
        let k = dollars / 1000
        let rounded = (k * 10).rounded() / 10
        return rounded == rounded.rounded() ? "$\(Int(rounded))k" : String(format: "$%.1fk", rounded)
    }
}
