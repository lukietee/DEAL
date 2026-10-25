import SwiftUI

/// Full-screen glanceable cue (phone fallback for the glasses, and the projector mirror):
/// 3–6 word cue, status color, current offer vs target. Tap anywhere to dismiss.
/// Styled as B3b in the redesign: sand page, status chip, huge cue, OFFER / TARGET tiles.
struct TeleprompterView: View {
    var display: PhoneTeleprompterDisplay
    @Environment(\.dismiss) private var dismiss
    @State private var flash = false

    var body: some View {
        let cue = display.currentCue
        let dot = cue?.status.dotColor ?? Palette.faint
        ZStack {
            Palette.sand.ignoresSafeArea()
            dot.opacity(flash ? 0.35 : 0).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Circle().fill(dot).frame(width: 16, height: 16)
                    Text(cue?.isAlert == true ? "ALERT" : (cue?.status.label.uppercased() ?? "STANDBY"))
                        .font(DealFont.jakarta(15, .extrabold))
                        .kerning(2)
                        .foregroundStyle(cue?.isAlert == true ? Palette.red : Palette.ink)
                }
                .padding(.leading, 12)
                .padding(.trailing, 16)
                .frame(height: 40)
                .background(Capsule().fill(Palette.surfaceWarm))

                Spacer(minLength: 24)

                VStack(alignment: .leading, spacing: 18) {
                    Text(cue?.text ?? "Waiting for cue")
                        .font(DealFont.jakarta(66, .extrabold))
                        .kerning(-3)
                        .lineSpacing(-4)
                        .foregroundStyle(Palette.ink)
                        .minimumScaleFactor(0.4)
                        .lineLimit(3)
                    if let detail = cue?.detail, !detail.isEmpty {
                        Text(detail)
                            .font(DealFont.jakarta(20, .regular))
                            .foregroundStyle(Palette.mutedWarm)
                            .lineSpacing(4)
                            .minimumScaleFactor(0.5)
                    }
                }
                .padding(.horizontal, 4)

                Spacer(minLength: 24)

                if let cue {
                    HStack(spacing: 12) {
                        tile(Money.format(cue.currentOffer, placeholder: "—"), "OFFER", valueColor: Palette.ink)
                        tile(Money.format(cue.target), "TARGET", valueColor: Palette.mutedWarm)
                    }
                }

                Text("Tap anywhere to close")
                    .font(DealFont.caption)
                    .foregroundStyle(Palette.navInactive)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 12)
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

    private func tile(_ value: String, _ label: String, valueColor: Color) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(DealFont.jakarta(34, .extrabold))
                .kerning(-1)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .font(DealFont.jakarta(12, .bold))
                .kerning(1.4)
                .foregroundStyle(Palette.mutedWarm)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surfaceWarm))
    }
}
