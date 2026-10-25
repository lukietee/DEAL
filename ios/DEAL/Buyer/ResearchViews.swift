import SwiftUI

// Live market research (three agents with web search) and suggested phrases, both delivered by the
// backend through `GET /sessions/:id` -> `research` / `suggestions` and refreshed by the normal sync.

// MARK: - Models

struct ResearchState: Codable, Sendable, Hashable {
    var item: String
    var status: String          // running | done
    var agents: [ResearchAgent]

    var isRunning: Bool { status != "done" }

    /// Overall fair range: the narrowest band the agents agree on.
    var priceRange: (low: Int, high: Int)? {
        let lows = agents.compactMap(\.priceLow), highs = agents.compactMap(\.priceHigh)
        guard let low = lows.max(), let high = highs.min(), low <= high else {
            guard let low = lows.min(), let high = highs.max() else { return nil }
            return (low, high)
        }
        return (low, high)
    }

    var allImages: [ResearchSource] {
        var seen = Set<String>()
        return agents.flatMap(\.sources).filter { $0.imageURL != nil && seen.insert($0.url).inserted }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        item = c.firstString(["item"]) ?? ""
        status = c.firstString(["status"]) ?? "running"
        agents = (try? c.decode([ResearchAgent].self, forKey: AnyKey("agents"))) ?? []
    }
}

struct ResearchAgent: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    var status: String          // queued | searching | reading | done | error
    var activity: String
    var queries: [String]
    var sources: [ResearchSource]
    var summary: String?
    var priceLow: Int?
    var priceHigh: Int?
    var error: String?

    var isActive: Bool { status == "searching" || status == "reading" || status == "queued" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.firstString(["id"]) ?? UUID().uuidString
        title = c.firstString(["title"]) ?? "Research"
        status = c.firstString(["status"]) ?? "queued"
        activity = c.firstString(["activity"]) ?? ""
        queries = (try? c.decode([String].self, forKey: AnyKey("queries"))) ?? []
        sources = (try? c.decode([ResearchSource].self, forKey: AnyKey("sources"))) ?? []
        summary = c.firstString(["summary"])
        priceLow = c.firstInt(["priceLow"])
        priceHigh = c.firstInt(["priceHigh"])
        error = c.firstString(["error"])
    }
}

struct ResearchSource: Codable, Sendable, Hashable, Identifiable {
    var title: String
    var url: String
    var price: Int?
    var note: String?
    var imageURL: URL?

    var id: String { url }
    var host: String { URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? "" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        url = c.firstString(["url"]) ?? ""
        title = c.firstString(["title"]) ?? url
        price = c.firstInt(["price"])
        note = c.firstString(["note"])
        imageURL = c.firstString(["imageUrl", "imageURL"]).flatMap(URL.init(string:))
    }
}

struct PhraseSuggestions: Codable, Sendable, Hashable {
    struct Phrase: Codable, Sendable, Hashable, Identifiable {
        var text: String
        var why: String
        var id: String { text }
    }
    var forEventId: String?
    var phrases: [Phrase]
}

// MARK: - Research panel (B3)

struct ResearchPanel: View {
    var research: ResearchState?
    var onRerun: () -> Void
    @State private var showDetail = false

    var body: some View {
        SurfaceCard(padding: 16) {
            HStack(spacing: 8) {
                if research?.isRunning ?? true {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.greenText)
                }
                Text("LIVE RESEARCH").font(DealFont.eyebrow).kerning(1.2).foregroundStyle(Palette.muted)
                Spacer()
                Text("\(research?.agents.count ?? 3) agents").font(DealFont.jakarta(12, .semibold)).foregroundStyle(Palette.muted)
                Button { showDetail = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Palette.sand))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open research")
            }

            if let range = research?.priceRange {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Fair range").font(DealFont.caption).foregroundStyle(Palette.muted)
                    Text("\(Money.format(range.low)) – \(Money.format(range.high))")
                        .font(DealFont.jakarta(22, .extrabold)).kerning(-0.5)
                }
            }

            if let research {
                ForEach(research.agents) { agent in
                    AgentRow(agent: agent)
                }
                let images = research.allImages
                if !images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(images.prefix(8)) { source in
                                SourceThumb(source: source, size: 76)
                                    .onTapGesture { showDetail = true }
                            }
                        }
                    }
                    .transition(.opacity)
                }
            } else {
                Text("Starting research agents…").font(DealFont.caption).foregroundStyle(Palette.muted)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: research)
        .sheet(isPresented: $showDetail) {
            ResearchDetailView(research: research, onRerun: onRerun)
        }
    }
}

private struct AgentRow: View {
    var agent: ResearchAgent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(agent.status == "done" ? Palette.sand : Palette.background).frame(width: 34, height: 34)
                if agent.isActive {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon).font(.system(size: 14, weight: .bold))
                        .foregroundStyle(agent.status == "error" ? Palette.red : Palette.ink)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.title).font(DealFont.jakarta(15, .bold))
                Text(agent.status == "done" ? (agent.summary ?? agent.activity) : agent.activity)
                    .font(DealFont.caption)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(agent.status == "done" ? 3 : 1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
        }
    }

    private var icon: String {
        switch agent.id {
        case "comps": "tag.fill"
        case "issues": "wrench.and.screwdriver.fill"
        default: "chart.line.uptrend.xyaxis"
        }
    }
}

private struct SourceThumb: View {
    var source: ResearchSource
    var size: CGFloat

    var body: some View {
        AsyncImage(url: source.imageURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Palette.sand
                    Image(systemName: "photo").foregroundStyle(Palette.mutedWarm)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if let price = source.price {
                Text(Money.format(price))
                    .font(DealFont.jakarta(11, .extrabold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Palette.surface))
                    .padding(5)
            }
        }
    }
}

/// Full research view: every agent's searches, summary and sources with pictures.
struct ResearchDetailView: View {
    var research: ResearchState?
    var onRerun: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let research {
                        Text(research.item).font(DealFont.cardTitle)
                        if let range = research.priceRange {
                            StatTile(value: "\(Money.format(range.low)) – \(Money.format(range.high))", label: "Fair range", height: 92)
                        }
                        ForEach(research.agents) { agent in
                            SurfaceCard {
                                HStack {
                                    Text(agent.title).font(DealFont.cardTitle)
                                    Spacer()
                                    Chip(text: agent.status, dot: agent.isActive ? Palette.amber : (agent.status == "done" ? Palette.green : Palette.red), fill: Palette.background, eyebrow: true)
                                }
                                if let summary = agent.summary { Text(summary).font(DealFont.body) }
                                ForEach(agent.queries, id: \.self) { q in
                                    Label(q, systemImage: "magnifyingglass").font(DealFont.caption).foregroundStyle(Palette.muted)
                                }
                                ForEach(agent.sources.prefix(6)) { source in
                                    Button { if let u = URL(string: source.url) { openURL(u) } } label: {
                                        HStack(spacing: 12) {
                                            SourceThumb(source: source, size: 64)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(source.title).font(DealFont.jakarta(14, .bold)).lineLimit(2).multilineTextAlignment(.leading)
                                                Text([source.host, source.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                                    .font(DealFont.caption).foregroundStyle(Palette.muted).lineLimit(1)
                                            }
                                            Spacer(minLength: 0)
                                            if let price = source.price {
                                                Text(Money.format(price)).font(DealFont.jakarta(15, .extrabold))
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    } else {
                        Text("Research hasn't started yet.").foregroundStyle(Palette.muted)
                    }
                }
                .padding(20)
            }
            .dealPage()
            .navigationTitle("Market research")
            .dealInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Run again") { onRerun() }.disabled(research?.isRunning ?? false)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Suggested phrases

struct SuggestedPhrasesCard: View {
    var suggestions: PhraseSuggestions?
    @State private var showWindow = false

    var body: some View {
        SurfaceCard(padding: 16, fill: Palette.ink) {
            HStack {
                Image(systemName: "text.bubble.fill").foregroundStyle(Palette.amber)
                Text("SAY THIS").font(DealFont.eyebrow).kerning(1.2).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button { showWindow = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Palette.surface))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open suggested phrases")
            }
            if let phrases = suggestions?.phrases, !phrases.isEmpty {
                ForEach(Array(phrases.enumerated()), id: \.element.id) { i, phrase in
                    PhraseRow(index: i + 1, phrase: phrase, large: false)
                }
            } else {
                Text("Suggestions appear as the conversation starts.").font(DealFont.caption).foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.3), value: suggestions)
        .fullScreenCover(isPresented: $showWindow) {
            SuggestedPhrasesWindow(suggestions: suggestions)
        }
    }
}

private struct PhraseRow: View {
    var index: Int
    var phrase: PhraseSuggestions.Phrase
    var large: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(DealFont.jakarta(large ? 16 : 12, .extrabold))
                .foregroundStyle(Palette.ink)
                .frame(width: large ? 30 : 22, height: large ? 30 : 22)
                .background(Circle().fill(Palette.amber))
            VStack(alignment: .leading, spacing: 4) {
                Text("“\(phrase.text)”").font(DealFont.jakarta(large ? 26 : 15, .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(phrase.why.uppercased()).font(DealFont.jakarta(large ? 13 : 10, .bold)).kerning(1).foregroundStyle(.white.opacity(0.55))
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// The separate full-screen "suggested phrases" window (big text, readable at arm's length).
struct SuggestedPhrasesWindow: View {
    var suggestions: PhraseSuggestions?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Palette.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("SAY THIS").font(DealFont.eyebrow).kerning(1.5).foregroundStyle(Palette.amber)
                    ForEach(Array((suggestions?.phrases ?? []).enumerated()), id: \.element.id) { i, phrase in
                        PhraseRow(index: i + 1, phrase: phrase, large: true)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 60)
                .foregroundStyle(.white)
            }
            CircleIconButton(systemName: "xmark", action: { dismiss() }).padding(20)
        }
        .animation(.easeInOut(duration: 0.3), value: suggestions)
    }
}
