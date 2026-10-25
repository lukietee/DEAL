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
    @State private var isStarting = false
    @State private var error: String?

    // Import listing
    @State private var listingLink = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var listing: Listing?
    @State private var listingNote: String?
    @State private var isImporting = false
    @State private var importError: String?
    /// Bumped by every fill/import so a slow import can't overwrite a newer choice (e.g. Car demo).
    @State private var fillGeneration = 0

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
        Form {
            importSection

            Section("Category") {
                Picker("Category", selection: $category) {
                    ForEach(DealCategory.allCases) { c in
                        Label(c.displayName, systemImage: c.symbol).tag(c)
                    }
                }
                .pickerStyle(.menu)
                HStack {
                    Button("Use demo values") { Task { await fillMarketplaceDemo() } }
                    Spacer()
                    Button { fillCarDemo() } label: { Label("Car demo", systemImage: "car.fill") }
                }
                .buttonStyle(.borderless)
                .font(.footnote)
            }

            Section("What are you buying?") {
                TextField("Item (e.g. used road bike)", text: $item)
                moneyField("Asking price", text: $asking)
                moneyField("Target price", text: $target)
                moneyField("Maximum budget", text: $maxBudget)
            }

            Section("Style") {
                Picker("Style", selection: $style) {
                    ForEach(NegotiationStyle.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                if loadingComparables {
                    ProgressView()
                } else if comparables.isEmpty {
                    Text(comparablesError ?? "No comparables for this category.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(comparables.prefix(4)) { comp in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(comp.title).font(.subheadline)
                                if let source = comp.source {
                                    Text(source).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(Money.format(comp.price)).font(.subheadline.monospacedDigit().weight(.semibold))
                        }
                    }
                }
            } header: {
                Text("Comparable prices")
            } footer: {
                Text("Illustrative listings for demo purposes.")
            }

            Section {
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Button {
                    Task { await start() }
                } label: {
                    HStack {
                        if isStarting { ProgressView().tint(.white) }
                        Text("Start Session")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(validationMessage != nil || isStarting)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                if let msg = validationMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("New Negotiation")
        .task(id: category) { await loadComparables() }
        .task { if item.isEmpty && listing == nil { await fillMarketplaceDemo() } }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task { await importScreenshot(newItem) }
        }
    }

    // MARK: Import listing

    private var importSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField("Paste a Marketplace link", text: $listingLink)
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
            }
            HStack {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Listing screenshot", systemImage: "photo.on.rectangle")
                }
                Spacer()
                Button {
                    Task { await importLink() }
                } label: {
                    if isImporting { ProgressView() } else { Text("Import") }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(listingLink.trimmingCharacters(in: .whitespaces).isEmpty || isImporting)
            }
            .buttonStyle(.borderless)
            if isImporting {
                Label("Reading listing…", systemImage: "text.viewfinder")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let importError {
                Text(importError).font(.footnote).foregroundStyle(.red)
            }
            if let listing {
                ListingCard(listing: listing, note: listingNote) { clearListing() }
            }
        } header: {
            Text("Import listing")
        } footer: {
            Text("Paste a Facebook Marketplace link or pick a screenshot. DEAL reads the price and what the seller claims about condition, then checks those claims at the meetup.")
        }
    }

    /// A link goes as `url`; anything else (pasted listing text) goes as `text`.
    private func importLink() async {
        let raw = listingLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let looksLikeURL = raw.lowercased().hasPrefix("http") || raw.contains("facebook.com") || raw.contains("fb.me")
        await runImport(note: nil) {
            try await model.api.parseListing(url: looksLikeURL ? raw : nil, text: looksLikeURL ? nil : raw)
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
            importError = "Couldn't import the listing. \(error.localizedDescription)"
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

    private func moneyField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("$").foregroundStyle(.secondary)
            TextField("0", text: text)
                .multilineTextAlignment(.trailing)
                .dealKeyboard(.decimal)
                .frame(maxWidth: 140)
        }
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
