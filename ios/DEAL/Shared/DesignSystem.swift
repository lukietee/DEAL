import SwiftUI

// Design tokens and building blocks from the "DEAL Redesign" Claude design
// (https://claude.ai/artifact/1qu61hDQeLKG9SFGTodHyy). Warm sand palette, Plus Jakarta Sans,
// big radii (28 cards, 56 hero corners), capsule buttons, tabular numbers.

// MARK: - Colors

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

enum Palette {
    static let background = Color(hex: 0xEEEBE6)   // page
    static let sand = Color(hex: 0xD1CBC1)         // hero, chips, secondary buttons
    static let surface = Color(hex: 0xFAFAFA)      // cards, nav, icon buttons
    static let surfaceWarm = Color(hex: 0xF4F1EC)  // nested rows inside cards
    static let ink = Color(hex: 0x111111)          // text, primary buttons
    static let inkSoft = Color(hex: 0x3A3A3A)
    static let muted = Color(hex: 0x5E5E5E)        // secondary text on surface
    static let mutedWarm = Color(hex: 0x57524A)    // secondary text on sand
    static let navInactive = Color(hex: 0x6B665E)
    static let faint = Color(hex: 0x9E9E9E)
    static let divider = Color(hex: 0xE6E6E6)
    static let grabber = Color(hex: 0xBDBDBD)
    static let dark = Color(hex: 0x2E2B27)         // teleprompter / terminal dark surfaces

    static let red = Color(hex: 0xC62828)          // blocked amounts, danger
    static let liveRed = Color(hex: 0xB3261E)      // "LIVE NOW" text
    static let liveDot = Color(hex: 0xFF5A4E)
    static let amber = Color(hex: 0xF5B800)        // waiting / careful
    static let green = Color(hex: 0x3DDC84)        // online / good dot
    static let greenText = Color(hex: 0x1E9E57)    // good text on light
}

// MARK: - Type

enum DealFont {
    enum Weight { case regular, medium, semibold, bold, extrabold }

    static func jakarta(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        let name = switch weight {
        case .regular: "PlusJakartaSans-Regular"
        case .medium: "PlusJakartaSans-Medium"
        case .semibold: "PlusJakartaSans-SemiBold"
        case .bold: "PlusJakartaSans-Bold"
        case .extrabold: "PlusJakartaSans-ExtraBold"
        }
        return .custom(name, size: size).monospacedDigit()
    }

    static func mono(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        let name = switch weight {
        case .regular: "GeistMono-Regular"
        case .medium: "GeistMono-Medium"
        default: "GeistMono-SemiBold"
        }
        return .custom(name, size: size)
    }

    /// The "welcome" handwriting on the mode picker.
    static func script(_ size: CGFloat) -> Font { .custom("Sacramento-Regular", size: size) }

    // Common roles
    static let title = jakarta(36, .extrabold)        // hero h1
    static let section = jakarta(24, .extrabold)      // "Totals", "Recent"
    static let cardTitle = jakarta(18, .extrabold)
    static let body = jakarta(16, .regular)
    static let bodyBold = jakarta(16, .bold)
    static let caption = jakarta(13, .regular)
    static let eyebrow = jakarta(12, .bold)           // "BUYER", "SPENT" (use with .kerning(1.2))
    static let button = jakarta(15, .bold)
}

extension View {
    /// Page defaults: warm background, ink text, Jakarta body.
    func dealPage() -> some View {
        self
            .font(DealFont.body)
            .foregroundStyle(Palette.ink)
            .tint(Palette.ink)
            .background(Palette.background.ignoresSafeArea())
    }
}

// MARK: - Surfaces

/// White rounded card (radius 28), the main container in the design.
struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = 18
    var fill: Color = Palette.surface
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(fill))
    }
}

/// Sand hero header with the design's signature corner notch: the hero's bottom-left corner
/// is rounded, and the page below it has its top-right corner rounded into the sand.
struct HeroScaffold<Hero: View, Content: View>: View {
    var heroBottomPadding: CGFloat = 64
    @ViewBuilder var hero: Hero
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            hero
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, heroBottomPadding)
                .background(
                    UnevenRoundedRectangle(bottomLeadingRadius: 56, style: .continuous)
                        .fill(Palette.sand)
                        .ignoresSafeArea(edges: .top)
                )
            VStack(alignment: .leading, spacing: 16) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .background(alignment: .top) {
                    ZStack(alignment: .top) {
                        Palette.sand.frame(height: 56)
                        UnevenRoundedRectangle(topTrailingRadius: 56, style: .continuous)
                            .fill(Palette.background)
                    }
                }
        }
        .foregroundStyle(Palette.ink)
    }
}

/// Bottom sheet look used by B3a join code / B3c fix / A1 settings: grabber + page background.
struct SheetGrabber: View {
    var body: some View {
        Capsule().fill(Palette.grabber).frame(width: 40, height: 5)
    }
}

// MARK: - Controls

/// 48pt circular icon button on the surface color (back, settings).
struct CircleIconButton: View {
    var systemName: String
    var fill: Color = Palette.surface
    var size: CGFloat = 48
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(Palette.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
        }
        .buttonStyle(.plain)
    }
}

/// Capsule button. `.ink` = black primary, `.sand`, `.surface` (white), `.danger` (red).
struct PillButtonStyle: ButtonStyle {
    enum Kind { case ink, sand, surface, danger, green }
    var kind: Kind = .ink
    var height: CGFloat = 56
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        let (bg, fg): (Color, Color) = switch kind {
        case .ink: (Palette.ink, .white)
        case .sand: (Palette.sand, Palette.ink)
        case .surface: (Palette.surface, Palette.ink)
        case .danger: (Palette.red, .white)
        case .green: (Palette.greenText, .white)
        }
        return configuration.label
            .font(DealFont.jakarta(height >= 52 ? 17 : 15, .bold))
            .lineLimit(1)
            .padding(.horizontal, 20)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background(Capsule().fill(bg))
            .foregroundStyle(fg)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Small capsule label: "BUYER", "Backend online" (with dot), "Waiting for seller".
struct Chip: View {
    var text: String
    var dot: Color? = nil
    var fill: Color = Palette.ink.opacity(0.12)
    var eyebrow = false

    var body: some View {
        HStack(spacing: 8) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            Text(eyebrow ? text.uppercased() : text)
                .font(eyebrow ? DealFont.eyebrow : DealFont.jakarta(13, .semibold))
                .kerning(eyebrow ? 1.2 : 0)
        }
        .padding(.horizontal, 14)
        .frame(height: eyebrow ? 32 : 36)
        .background(Capsule().fill(fill))
    }
}

/// Big number tile ("$35,820 / SPENT").
struct StatTile: View {
    var value: String
    var label: String
    var valueColor: Color = Palette.ink
    var height: CGFloat = 104

    var body: some View {
        VStack(spacing: 6) {
            Text(value)
                .font(DealFont.jakarta(32, .extrabold))
                .kerning(-1)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label.uppercased())
                .font(DealFont.jakarta(12, .semibold))
                .kerning(1.2)
                .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: height)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
    }
}

/// Section heading ("Totals", "Recent") with an optional trailing capsule action.
struct SectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(DealFont.section).kerning(-0.5)
            Spacer()
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// Circular icon badge (44pt, sand) used at the start of list rows.
struct IconBadge: View {
    var systemName: String
    var fill: Color = Palette.sand
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
    }
}
