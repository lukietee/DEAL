import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Theme

enum Theme {
    static let accent = Color(red: 0.10, green: 0.32, blue: 0.85)   // Visa-ish blue
    static let gold = Color(red: 0.97, green: 0.71, blue: 0.0)
    static let cardBackground = Color.secondary.opacity(0.10)
    static let cornerRadius: CGFloat = 14
}

extension StatusColor {
    var color: Color {
        switch self {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        case .unknown: .gray
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint ?? .secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
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
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint))
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

/// Offer vs target bar ("[██████████░░░] near target").
struct OfferProgressBar: View {
    var asking: Int
    var target: Int
    var maxBudget: Int
    var offer: Int?

    var body: some View {
        let progress = OfferMath.progress(asking: asking, target: target, offer: offer) ?? 0
        let label = OfferMath.label(asking: asking, target: target, maxBudget: maxBudget, offer: offer)
        let status = OfferMath.status(target: target, maxBudget: maxBudget, offer: offer)
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(status.color.gradient)
                        .frame(width: max(8, geo.size.width * progress))
                        .animation(.spring(duration: 0.4), value: progress)
                }
            }
            .frame(height: 10)
            Text(label.rawValue).font(.caption).foregroundStyle(.secondary)
        }
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

/// Join code + QR shown to the buyer after Start Session (B2 -> B3).
struct JoinCodeCard: View {
    var code: String
    var body: some View {
        VStack(spacing: 14) {
            Text("Seller joins with").font(.subheadline).foregroundStyle(.secondary)
            QRCodeView(payload: JoinCode.qrPayload(code))
                .frame(width: 200, height: 200)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 16).fill(.white))
            Text(code)
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .kerning(6)
                .textSelection(.enabled)
            Text("Seller: open DEAL → I'm Selling → scan or type this code.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
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
        HStack(alignment: .top, spacing: 8) {
            Text(event.speaker.displayName + ":")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(event.speaker == .buyer ? Theme.accent : .orange)
                .frame(width: 52, alignment: .leading)
            Text(event.text)
                .font(.subheadline)
                .lineLimit(compact ? 2 : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !compact, let ts = event.timestamp {
                Text(TimeFormat.clock(ts)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// The ON GLASSES card. Mirrors exactly what the `GlassesDisplay` is showing.
struct GlassesCueCard: View {
    var cue: GlassesCue?
    var displayName: String

    var body: some View {
        Card(title: "On glasses · \(displayName)", tint: cue?.status.color ?? .gray) {
            if let cue {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StatusDot(color: cue.status.color, size: 12)
                    Text(cue.text).font(.title3.weight(.semibold))
                }
                if let detail = cue.detail, !detail.isEmpty {
                    Text(detail).font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                }
            } else {
                Text("Waiting for the conversation…").foregroundStyle(.secondary)
            }
        }
    }
}
