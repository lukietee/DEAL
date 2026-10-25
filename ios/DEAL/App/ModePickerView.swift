import SwiftUI

/// Main: sand hero (backend status, settings, "welcome Lucas"), "Pick your side" cards
/// (I'm Buying / I'm Selling) and the glasses connection row.
struct ModePickerView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            HeroScaffold(heroBottomPadding: 76) {
                hero
            } content: {
                SectionHeader(title: "Pick your side")
                    .padding(.top, 24)
                HStack(spacing: 12) {
                    ModeCard(title: "I'm Buying", subtitle: "Coach me and protect my payment",
                             symbol: "checkmark.shield.fill", fill: Palette.sand, badgeFill: Palette.surface,
                             subtitleColor: Palette.mutedWarm) {
                        model.mode = .buyer
                    }
                    ModeCard(title: "I'm Selling", subtitle: "Join a buyer's session and take payment",
                             symbol: "wave.3.right", fill: Palette.surface, badgeFill: Palette.sand,
                             subtitleColor: Palette.muted) {
                        model.mode = .seller
                    }
                }
                glassesRow
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(alignment: .top) {
            // Keep the sand behind the status bar when the scroll view rubber-bands.
            Palette.sand.frame(height: 200).ignoresSafeArea(edges: .top)
        }
        .dealPage()
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task { await model.checkBackend() }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack {
                backendChip
                Spacer()
                CircleIconButton(systemName: "gearshape") { showSettings = true }
                    .accessibilityLabel("Settings")
            }
            VStack(alignment: .leading, spacing: 0) {
                ScriptWelcome()
                HStack(spacing: 14) {
                    Text("Lucas")
                        .font(DealFont.jakarta(76, .extrabold))
                        .kerning(-3.4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    AvatarImage()
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                        .accessibilityLabel("Lucas's avatar")
                }
                .frame(height: 72)
                .padding(.top, -12)
                Text("Negotiate. Lock it in. Pay exactly that.")
                    .font(DealFont.jakarta(15))
                    .foregroundStyle(Palette.mutedWarm)
                    .padding(.top, 10)
            }
        }
    }

    private var backendChip: some View {
        let (text, dot): (String, Color) = switch model.backendReachable {
        case .some(true): ("Backend online", Palette.green)
        case .some(false): ("Backend offline", Palette.red)
        case .none: ("Checking backend…", Palette.faint)
        }
        return Chip(text: text, dot: dot)
            .contentShape(Capsule())
            .onTapGesture { Task { await model.checkBackend() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Checks the backend again")
    }

    // MARK: Glasses

    private var glassesStatusText: String {
        switch model.metaGlasses.status {
        case .failed: "Failed · retry"
        default: model.metaGlasses.status.label
        }
    }

    private var glassesDot: Color {
        switch model.metaGlasses.status {
        case .connected: Palette.green
        case .failed: Palette.red
        case .off: Color(hex: 0x9A9A9A)
        default: Palette.amber
        }
    }

    private var glassesAction: String {
        switch model.metaGlasses.status {
        case .off: "Connect"
        case .failed: "Retry"
        default: model.metaGlasses.wantsConnection ? "Manage" : "Connect"
        }
    }

    private var glassesRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 22, weight: .medium))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Glasses").font(DealFont.jakarta(16, .bold))
                HStack(spacing: 6) {
                    Circle().fill(glassesDot).frame(width: 7, height: 7)
                    Text(glassesStatusText)
                        .font(DealFont.jakarta(13))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(glassesAction) {
                if model.metaGlasses.wantsConnection { showSettings = true } else { model.metaGlasses.connect() }
            }
            .buttonStyle(PillButtonStyle(kind: .sand, height: 44, fullWidth: false))
            .accessibilityIdentifier("glassesStatus")
        }
        .padding(.vertical, 12)
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
    }
}

/// `avatar.png` ships as a loose bundle resource (not in an asset catalog), so load it via UIImage.
private struct AvatarImage: View {
    var body: some View {
        #if os(iOS)
        if let ui = UIImage(named: "avatar") {
            Image(uiImage: ui).resizable().scaledToFill()
        } else {
            Circle().fill(Palette.surface)
        }
        #else
        Image("avatar").resizable().scaledToFill()
        #endif
    }
}

/// "welcome" in Sacramento with the mockup's 1.6px text stroke, faked by stacking offset copies.
private struct ScriptWelcome: View {
    var body: some View {
        let offsets: [CGSize] = [.zero, .init(width: 0.8, height: 0), .init(width: -0.8, height: 0),
                                 .init(width: 0, height: 0.8), .init(width: 0, height: -0.8)]
        ZStack {
            ForEach(offsets.indices, id: \.self) { i in
                Text("welcome").offset(offsets[i])
            }
        }
        .font(DealFont.script(72))
        .padding(.leading, -4)
        .frame(height: 66, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("welcome")
    }
}

private struct ModeCard: View {
    var title: String
    var subtitle: String
    var symbol: String
    var fill: Color
    var badgeFill: Color
    var subtitleColor: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                IconBadge(systemName: symbol, fill: badgeFill, size: 48)
                Spacer(minLength: 12)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(DealFont.jakarta(21, .extrabold))
                        .kerning(-0.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(subtitle)
                        .font(DealFont.jakarta(13))
                        .foregroundStyle(subtitleColor)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(Palette.ink)
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 172, maxHeight: 172, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(fill))
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}
