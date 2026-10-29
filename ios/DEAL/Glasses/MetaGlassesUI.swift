import SwiftUI
#if DEBUG
import MWDATMockDevice
#endif

// SwiftUI helpers for `MetaGlassesDisplay` (kept out of MetaGlassesDisplay.swift so the
// MWDATDisplay `Text` / `Image` names don't clash with SwiftUI's).

extension MetaGlassesStatus {
    var color: Color {
        switch self {
        case .connected: .green
        case .failed: .red
        case .off: .gray
        default: .yellow
        }
    }
}

// MARK: - Glasses cards (the demo video's "ON YOUR GLASSES" design)

/// Renders what the glasses show as the demo video's cards: a dark #2E2B27 card, a status dot and
/// a Geist Mono caps label, then a big Jakarta ExtraBold line. The display's own text styles can't
/// do any of that, so `MetaGlassesDisplay` sends these as one image (nil -> its text layout).
/// Sized in display pixels for the 600 px wide Ray-Ban Display canvas, matching the video 1:1.
@MainActor
enum MetaGlassesCards {
    static let canvasWidth: CGFloat = 600

    static func cue(_ cue: GlassesCue, market: GlassesMarket?) -> UIImage? {
        let status = cue.isAlert || cue.label != nil ? StatusColor.red : cue.status   // mismatch cards are red in the video
        let word = cue.isAlert ? "ALERT" : (cue.status == .unknown ? "CUE" : cue.status.label.uppercased())
        let lines = cue.context + (cue.detail.flatMap { $0.isEmpty ? nil : [$0] } ?? [])
        return render {
            VStack(alignment: .leading, spacing: 16) {
                GlassesHUDCard(dot: status.dotColor, label: cue.label ?? "\(word) · ON YOUR GLASSES") {
                    if !lines.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(lines, id: \.self) { GlassesHUDLine(text: $0) }
                        }
                        .padding(.bottom, 4)
                    }
                    GlassesHUDTitle(text: cue.text)
                }
                if let market { marketCard(market) }
            }
        }
    }

    static func research(_ research: GlassesResearch) -> UIImage? {
        let label = research.isRunning ? "RESEARCH · \(research.doneCount)/\(research.rows.count) AGENTS" : "RESEARCH · DONE"
        return render {
            GlassesHUDCard(dot: research.isRunning ? Palette.amber : Palette.green, label: label) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(research.rows, id: \.label) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Circle().fill(row.phase == .done ? Palette.green : row.phase == .failed ? Palette.liveDot : Palette.amber)
                                .frame(width: 11, height: 11)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                            Text(row.label.uppercased())
                                .font(DealFont.mono(18, .medium)).kerning(2.5)
                                .foregroundStyle(GlassesHUD.label)
                                .frame(width: 92, alignment: .leading)
                            Text(row.text)
                                .font(DealFont.jakarta(27, row.phase == .done ? .bold : .medium))
                                .foregroundStyle(row.phase == .done ? Color.white : GlassesHUD.muted)
                                .lineLimit(1).minimumScaleFactor(0.6)
                        }
                    }
                }
            }
        }
    }

    static func standby() -> UIImage? {
        render {
            GlassesHUDCard(dot: Palette.green, label: "DEAL · ON YOUR GLASSES") {
                GlassesHUDTitle(text: "Glasses connected")
                GlassesHUDLine(text: "Cues appear here during a negotiation")
            }
        }
    }

    static func look(_ look: LookHighlight, name: String, price: String, summary: String?,
                     meta: [String], hint: String) -> UIImage? {
        render {
            GlassesHUDCard(dot: Palette.green, label: look.expanded ? "LOOK · DETAILS" : "LOOK · MARKET PRICE") {
                GlassesHUDLine(text: name)
                GlassesHUDTitle(text: price)
                if let summary { GlassesHUDLine(text: summary).padding(.top, 2) }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ").uppercased())
                        .font(DealFont.mono(18, .medium)).kerning(2.5)
                        .foregroundStyle(GlassesHUD.label)
                        .padding(.top, 4)
                }
                Text(hint)
                    .font(DealFont.jakarta(22, .medium))
                    .foregroundStyle(GlassesHUD.muted)
                    .padding(.top, 6)
            }
        }
    }

    /// "● MARKET · 3 AGENTS" over "$590 – $725 fair range", hugging its content like the video.
    private static func marketCard(_ market: GlassesMarket) -> some View {
        let range = market.low == market.high
            ? Money.format(market.low) : "\(Money.format(market.low)) – \(Money.format(market.high))"
        let agents = market.agentCount == 1 ? "1 AGENT" : "\(market.agentCount) AGENTS"
        return GlassesHUDCard(dot: Palette.green, label: "MARKET · \(agents)", hug: true) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                GlassesHUDTitle(text: range)
                Text("fair range")
                    .font(DealFont.jakarta(27, .medium))
                    .foregroundStyle(GlassesHUD.muted)
            }
        }
    }

    private static func render(@ViewBuilder _ content: () -> some View) -> UIImage? {
        let renderer = ImageRenderer(content: content()
            .frame(width: canvasWidth, alignment: .topLeading)
            .environment(\.colorScheme, .dark))
        renderer.scale = 1
        renderer.isOpaque = false
        return renderer.uiImage
    }
}

private enum GlassesHUD {
    static let card = Palette.dark
    static let label = Color(hex: 0xCFCAC2)
    static let text = Color(hex: 0xDDD8D0)
    static let muted = Color(hex: 0xA8A39B)
}

/// The dark rounded card from the video: dot + mono caps label, then its content.
private struct GlassesHUDCard<Content: View>: View {
    var dot: Color
    var label: String
    var hug = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Circle().fill(dot).frame(width: 12, height: 12)
                Text(label)
                    .font(DealFont.mono(18, .medium))
                    .kerning(2.5)
                    .foregroundStyle(GlassesHUD.label)
                    .lineLimit(1)
            }
            content
        }
        .padding(.horizontal, 32)
        .padding(.top, 26)
        .padding(.bottom, 28)
        .frame(maxWidth: hug ? nil : .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(GlassesHUD.card))
        .fixedSize(horizontal: hug, vertical: true)
    }
}

private struct GlassesHUDTitle: View {
    var text: String

    var body: some View {
        Text(text)
            .font(DealFont.jakarta(44, .extrabold))
            .kerning(-1.5)
            .lineSpacing(-4)
            .foregroundStyle(.white)
            .lineLimit(3)
            .minimumScaleFactor(0.6)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GlassesHUDLine: View {
    var text: String

    var body: some View {
        Text(text)
            .font(DealFont.jakarta(27, .medium))
            .foregroundStyle(GlassesHUD.text)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Settings → Glasses: connection status, Connect / Disconnect, debug mock preview.
struct MetaGlassesSettingsRows: View {
    var glasses: MetaGlassesDisplay

    var body: some View {
        HStack {
            StatusDot(color: glasses.status.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(glasses.name)
                if let device = glasses.deviceName {
                    Text(glasses.isMock ? "\(device) (mock)" : device)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if glasses.status.isBusy { ProgressView().padding(.trailing, 4) }
            Text(glasses.status.label).foregroundStyle(.secondary)
        }
        if glasses.wantsConnection {
            Button("Disconnect glasses", role: .destructive) { glasses.disconnect() }
        } else {
            Button("Connect glasses") { glasses.connect() }
        }
        if let error = glasses.lastError {
            Text(error).font(.footnote).foregroundStyle(.red)
        }
        #if DEBUG
        Toggle("Mock glasses (phone preview)", isOn: Binding(
            get: { glasses.isMock },
            set: { on in
                if on { Task { await glasses.enableMockGlasses() } } else { glasses.disableMockGlasses() }
            }))
        #endif
    }
}

#if DEBUG
/// MockDeviceKit's render of the simulated glasses display.
struct MockGlassesPreview: UIViewRepresentable {
    let display: any MockDisplayKit

    func makeUIView(context: Context) -> UIView { display.createPreviewView() }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
