import SwiftUI

/// Full-screen glanceable cue (phone fallback for the glasses, and the projector mirror):
/// 3–6 word cue, status color, current offer vs target. Tap anywhere to dismiss.
struct TeleprompterView: View {
    var display: PhoneTeleprompterDisplay
    @Environment(\.dismiss) private var dismiss
    @State private var flash = false

    var body: some View {
        let cue = display.currentCue
        let color = cue?.status.color ?? .gray
        ZStack {
            Color.black.ignoresSafeArea()
            color.opacity(flash ? 0.45 : 0.18).ignoresSafeArea()

            VStack(spacing: 28) {
                HStack {
                    Circle().fill(color).frame(width: 22, height: 22)
                        .shadow(color: color, radius: 10)
                    Text(cue?.isAlert == true ? "ALERT" : (cue?.status.label.uppercased() ?? "STANDBY"))
                        .font(.headline.weight(.heavy)).foregroundStyle(color)
                    Spacer()
                }

                Spacer()

                Text(cue?.text ?? "Waiting for cue")
                    .font(.system(size: 54, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.4)
                    .lineLimit(3)

                if let detail = cue?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.5)
                }

                Spacer()

                if let cue {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading) {
                            Text("OFFER").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                            Text(Money.format(cue.currentOffer, placeholder: "—"))
                                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        }
                        Spacer()
                        Image(systemName: "arrow.right").foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("TARGET").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                            Text(Money.format(cue.target))
                                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        }
                    }
                    .foregroundStyle(.white)
                }

                Text("Tap to close").font(.caption).foregroundStyle(.white.opacity(0.4))
            }
            .padding(28)
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .dealKeepAwake()
        .onChange(of: display.revision) {
            withAnimation(.easeOut(duration: 0.15)) { flash = true }
            withAnimation(.easeIn(duration: 0.6).delay(0.2)) { flash = false }
            if display.currentCue?.isAlert == true { Platform.haptic(.error) }
        }
        #if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
    }
}
