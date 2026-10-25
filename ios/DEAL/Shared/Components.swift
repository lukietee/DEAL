import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Theme

enum Theme {
    // Mapped onto the redesign palette (DesignSystem.swift) so older call sites follow it.
    static let accent = Palette.ink
    static let gold = Palette.amber
    static let cardBackground = Palette.surface
    static let cornerRadius: CGFloat = 28
}

extension StatusColor {
    var color: Color {
        switch self {
        case .green: Palette.greenText
        case .yellow: Palette.amber
        case .red: Palette.red
        case .unknown: Palette.faint
        }
    }

    var label: String {
        switch self {
        case .green: "Good"
        case .yellow: "Careful"
        case .red: "Warning"
        case .unknown: "—"
        }
    }
}

// MARK: - Reusable pieces

struct Card<Content: View>: View {
    var title: String?
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(DealFont.eyebrow)
                    .kerning(1.2)
                    .foregroundStyle(tint ?? Palette.muted)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(tint?.opacity(0.10) ?? Theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(tint?.opacity(0.6) ?? .clear, lineWidth: tint == nil ? 0 : 1.5)
        )
    }
}

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 10
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

struct LiveBadge: View {
    var text = "LIVE"
    var color: Color = .red
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(), value: pulse)
            Text(text).font(.caption.weight(.bold)).foregroundStyle(color)
        }
        .onAppear { pulse = true }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DealFont.jakarta(17, .bold))
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Capsule().fill(tint))
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct ErrorBanner: View {
    var message: String
    var onDismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) { Image(systemName: "xmark").font(.footnote) }
                .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.15)))
        .padding(.horizontal)
    }
}

/// Offer vs target meter: track from asking (left) to target (right), filled up to the current
/// offer with a status-colored knob, a tick at the max budget, and "$100 over target" on the right.
struct OfferProgressBar: View {
    var asking: Int
    var target: Int
    var maxBudget: Int
    var offer: Int?

    private static let filled = Color(hex: 0x8C8478)
    private static let track = Color(hex: 0xE0E0E0)

    var body: some View {
        let progress = OfferMath.progress(asking: asking, target: target, offer: offer) ?? 0
        let status = OfferMath.status(target: target, maxBudget: maxBudget, offer: offer)
        let maxPos = OfferMath.progress(asking: asking, target: target, offer: maxBudget)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Self.track)
                    Capsule().fill(Self.filled)
                        .frame(width: offer == nil ? 0 : max(8, w * progress))
                    if maxBudget > 0, let maxPos, maxPos > 0, maxPos < 1 {
                        Rectangle().fill(Palette.surface).frame(width: 2, height: 14)
                            .offset(x: w * maxPos - 1)
                    }
                    if offer != nil {
                        Circle().fill(status.dotColor)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(Palette.surface, lineWidth: 2))
                            .offset(x: min(max(w * progress - 7, -2), w - 12))
                    }
                }
                .animation(.spring(duration: 0.4), value: progress)
            }
            .frame(height: 8)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    Text("Ask \(CompactMoney.short(asking))")
                    if maxBudget > 0, let maxPos, maxPos > 0.22, maxPos < 0.62 {
                        Text("Max \(CompactMoney.short(maxBudget))")
                            .fixedSize()
                            .frame(width: 90)
                            .offset(x: w * maxPos - 45)
                    }
                    Text(meterLabel)
                        .foregroundStyle(Palette.ink)
                        .frame(width: w, alignment: .trailing)
                }
                .font(DealFont.jakarta(11, .semibold))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
            }
            .frame(height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OfferMath.label(asking: asking, target: target, maxBudget: maxBudget, offer: offer).rawValue)
    }

    /// "$100 over target", "$400 under target", "At target", or the progress label without an offer.
    private var meterLabel: String {
        guard let offer else { return OfferProgressLabel.noOffer.rawValue.capitalizedFirst }
        let diff = offer - target
        if diff == 0 { return "At target" }
        return diff > 0 ? "\(Money.format(diff)) over target" : "\(Money.format(-diff)) under target"
    }
}

extension StatusColor {
    /// Bright status dot used on the sand hero and meters (the design's #3DDC84 / amber / red).
    var dotColor: Color {
        switch self {
        case .green: Palette.green
        case .yellow: Palette.amber
        case .red: Palette.liveDot
        case .unknown: Palette.faint
        }
    }
}

/// `$34.5k`, `$38k`, `$650`.
enum CompactMoney {
    static func short(_ cents: Int) -> String {
        let dollars = Double(cents) / 100
        guard dollars >= 1000 else { return Money.format(cents) }
        let k = ((dollars / 1000) * 10).rounded() / 10
        return k == k.rounded() ? "$\(Int(k))k" : String(format: "$%.1fk", k)
    }
}

struct QRCodeView: View {
    var payload: String

    var body: some View {
        if let image = Self.makeImage(payload) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "qrcode").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }

    static func makeImage(_ payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

/// Join code + QR shown to the buyer after Start Session (B2 -> B3), as the B3a sheet:
/// status chip + Done, "Seller joins with", QR on a white tile, the code in sand tiles.
struct JoinCodeCard: View {
    var code: String
    /// No conversation yet: show "Waiting for seller" (amber) instead of "Live".
    var waiting = true
    var onDone: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 18) {
            if let onDone {
                HStack {
                    Chip(text: waiting ? "Waiting for seller" : "Live",
                         dot: waiting ? Palette.amber : Palette.liveDot,
                         fill: Palette.surface)
                        .foregroundStyle(Palette.inkSoft)
                    Spacer()
                    Button("Done", action: onDone)
                        .buttonStyle(PillButtonStyle(kind: .sand, height: 44, fullWidth: false))
                }
            }
            Text("Seller joins with")
                .font(DealFont.jakarta(28, .extrabold))
                .kerning(-0.8)
            QRCodeView(payload: JoinCode.qrPayload(code))
                .frame(width: 200, height: 200)
                .padding(22)
                .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(Palette.surface))
            HStack(spacing: 6) {
                ForEach(Array(code.enumerated()), id: \.offset) { _, ch in
                    Text(String(ch))
                        .font(DealFont.jakarta(30, .extrabold))
                        .frame(width: 48, height: 60)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.sand))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(code)
            (Text("Seller: open DEAL → ") + Text("I'm Selling").foregroundStyle(Palette.ink).fontWeight(.bold)
             + Text(" → scan or type this code."))
                .font(DealFont.jakarta(14))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }
}

struct LabeledAmountRow: View {
    var label: String
    var amount: Int?
    var note: String? = nil
    var emphasized = false
    var highlight: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(emphasized ? .headline : .body)
                if let note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(Money.format(amount, placeholder: "—"))
                .font(emphasized ? .headline.monospacedDigit() : .body.monospacedDigit())
        }
        .padding(.vertical, highlight == nil ? 0 : 6)
        .padding(.horizontal, highlight == nil ? 0 : 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(highlight?.opacity(0.18) ?? .clear))
    }
}

/// A transcript line with speaker + time, used in B3, B4 (source links), B5 (contradiction).
struct TranscriptLineView: View {
    var event: DealEvent
    var compact = false

    var body: some View {
        let isBuyer = event.speaker == .buyer
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.speaker.displayName)
                .font(DealFont.jakarta(14, .extrabold))
                .foregroundStyle(isBuyer ? Palette.ink : Palette.muted)
                .frame(width: 50, alignment: .leading)
            Text(event.text)
                .font(DealFont.jakarta(14))
                .foregroundStyle(isBuyer ? Palette.ink : Palette.inkSoft)
                .lineSpacing(3)
                .lineLimit(compact ? 2 : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !compact, let ts = event.timestamp {
                Text(TimeFormat.clock(ts)).font(DealFont.jakarta(11)).foregroundStyle(Palette.muted)
            }
        }
    }
}

/// The ON GLASSES cue as it sits on the B3 sand hero: "● GOOD · ON GLASSES" over the big cue.
/// Mirrors exactly what the `GlassesDisplay` is showing.
struct GlassesCueCard: View {
    var cue: GlassesCue?
    var displayName: String
    var compact = false

    var body: some View {
        let word = cue.map { $0.isAlert ? "ALERT" : $0.status.label.uppercased() } ?? "STANDBY"
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(cue?.status.dotColor ?? Palette.faint).frame(width: 10, height: 10)
                Text("\(word) · ON GLASSES")
                    .font(DealFont.jakarta(11, .extrabold))
                    .kerning(1.5)
                    .foregroundStyle(Palette.mutedWarm)
            }
            Text(cue?.text ?? "Waiting for the conversation…")
                .font(DealFont.jakarta(compact ? 26 : 34, .extrabold))
                .kerning(compact ? -0.6 : -1)
                .foregroundStyle(cue == nil ? Palette.mutedWarm : Palette.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = cue?.detail, !detail.isEmpty {
                Text(detail)
                    .font(DealFont.jakarta(15, .semibold))
                    .foregroundStyle(Palette.mutedWarm)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("On \(displayName)")
    }
}
