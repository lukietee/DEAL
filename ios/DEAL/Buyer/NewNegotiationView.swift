import SwiftUI

/// B2. New Negotiation: category, item, asking/target/max, style, comparables, Start Session.
struct NewNegotiationView: View {
    @Environment(AppModel.self) private var model

    @State private var category: DealCategory = .car
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
            Section("Category") {
                Picker("Category", selection: $category) {
                    ForEach(DealCategory.allCases) { c in
                        Label(c.displayName, systemImage: c.symbol).tag(c)
                    }
                }
                .pickerStyle(.menu)
                Button("Use demo values") { fillDemo() }
                    .font(.footnote)
            }

            Section("What are you buying?") {
                TextField("Item (e.g. 2023 Honda Accord EX)", text: $item)
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
        .onAppear { if item.isEmpty { fillDemo() } }
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

    private func fillDemo() {
        switch category {
        case .pawnShop:
            item = "Fender Player Stratocaster (used)"
            asking = "650"; target = "500"; maxBudget = "575"
        default:
            item = "2023 Honda Accord EX"
            asking = "38000"; target = "34500"; maxBudget = "36000"
        }
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

    private func start() async {
        guard validationMessage == nil, let a = askingCents, let t = targetCents, let m = maxCents else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            let session = try await model.api.createSession(CreateSessionBody(
                category: category.rawValue, item: item.trimmingCharacters(in: .whitespaces),
                askingPrice: a, targetPrice: t, maxBudget: m, style: style.rawValue))
            error = nil
            _ = model.makeStore(role: .buyer, session: session)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
