import AVFoundation
import SwiftUI

/// Look mode (from B1): the live view of the glasses camera (or the iPhone camera / demo feed),
/// with the item DEAL is sure about highlighted in green and its market price in a small window
/// above it. Neural Band gestures drive it; the round buttons at the bottom send the same gestures
/// when no glasses are attached. The glasses themselves get a compact card (they can't draw a box
/// on the real object).
struct LookView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var scanner: LookScanner?
    /// The on-screen gesture buttons inject through this, the same path as the Neural Band.
    @State private var pad = PhoneGestureSource()
    @State private var startingNegotiation = false
    @State private var negotiateError: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let scanner {
                LookCameraOverlay(scanner: scanner)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar(scanner)
                    Spacer()
                    if !scanner.isEnabled { offCard(scanner) }
                    Spacer()
                    if let negotiateError {
                        Text(negotiateError)
                            .font(DealFont.jakarta(13, .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(Palette.red))
                            .padding(.bottom, 8)
                    }
                    LookGesturePad(scanner: scanner, pad: pad, busy: startingNegotiation)
                }
                .padding(.horizontal, 16)
            }
        }
        .preferredColorScheme(.dark)
        .buyerHiddenNavBar()
        .task {
            guard scanner == nil else { return }
            let s = LookScanner(frames: LookSources.frames(model: model), gestures: LookSources.gestures(model: model, pad: pad), api: model.api)
            s.onNegotiate = { highlight in Task { await negotiate(highlight) } }
            // The glasses get a compact card (they can't draw on the real object).
            s.onGlassesUpdate = { [glasses = model.metaGlasses] highlight in glasses.showLook(highlight) }
            scanner = s
            Platform.setIdleTimerDisabled(true)
        }
        .onDisappear {
            scanner?.stop()
            model.metaGlasses.showLook(nil)
            Platform.setIdleTimerDisabled(false)
        }
    }

    // MARK: Chrome

    private func topBar(_ scanner: LookScanner) -> some View {
        HStack(spacing: 10) {
            Button { scanner.stop(); dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.ultraThinMaterial))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .accessibilityIdentifier("lookBack")
            LookStatusPill(scanner: scanner)
            Spacer(minLength: 0)
            LookToggle(isOn: scanner.isEnabled) {
                Task { await scanner.setEnabled(!scanner.isEnabled) }
            }
        }
        .padding(.top, 6)
    }

    /// Shown while Look is off (the default): what it does, and the switch.
    private func offCard(_ scanner: LookScanner) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "eye")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Palette.ink)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Palette.green))
            Text("Look at a product.\nSee its price.")
                .font(DealFont.jakarta(26, .extrabold)).kerning(-0.6)
                .foregroundStyle(Palette.ink)
            Text("Hold your gaze on an item for a second. DEAL highlights it only when it's sure it's a product, and never the same thing twice.")
                .font(DealFont.jakarta(14))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button { Task { await scanner.setEnabled(true) } } label: {
                Label("Turn on Look", systemImage: "eye.fill")
            }
            .buttonStyle(PillButtonStyle(kind: .ink, height: 52))
            .accessibilityIdentifier("lookTurnOn")
            .padding(.top, 4)
            if case .failed(let message) = scanner.status {
                Text(message).font(DealFont.caption).foregroundStyle(Palette.red)
            }
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
        .environment(\.colorScheme, .light)
    }

    // MARK: Negotiate

    /// `.negotiate`: a session for this item, with the market range as target / max. B3 takes
    /// over the screen (BuyerFlowView pops back to its root when a session starts).
    private func negotiate(_ highlight: LookHighlight) async {
        guard !startingNegotiation, let name = highlight.identification.name else { return }
        startingNegotiation = true
        defer { startingNegotiation = false }
        let category = DealCategory(rawValue: highlight.identification.category ?? "") ?? .marketplace
        do {
            let session = try await model.api.createSession(CreateSessionBody(
                category: category.rawValue, item: name,
                targetPrice: highlight.price?.priceLow, maxBudget: highlight.price?.priceHigh,
                style: NegotiationStyle.firm.rawValue))
            negotiateError = nil
            scanner?.stop()
            _ = model.makeStore(role: .buyer, session: session)
        } catch {
            negotiateError = "Couldn't start the negotiation"
        }
    }
}

/// Where Look gets frames and gestures: the glasses when they're connected, else the iPhone's
/// back camera. The demo feed runs with `-DEALLookDemo`, or with Demo shortcuts on a device
/// without a camera (the Simulator).
@MainActor
enum LookSources {
    static func frames(model: AppModel) -> LookFrameSource {
        if ProcessInfo.processInfo.arguments.contains(LookDemoFrameSource.launchArgument) {
            return LookDemoFrameSource()
        }
        if model.metaGlasses.wantsConnection {
            return GlassesCamera(glasses: model.metaGlasses)
        }
        if AVCaptureDevice.default(for: .video) == nil, model.settings.demoShortcuts {
            return LookDemoFrameSource()
        }
        return PhoneCameraSource()
    }

    /// The on-screen pad, plus the Neural Band when glasses are connected, as one source.
    static func gestures(model: AppModel, pad: PhoneGestureSource) -> LookGestureSource {
        model.metaGlasses.wantsConnection
            ? MergedGestureSource([GlassesInputs(glasses: model.metaGlasses), pad])
            : MergedGestureSource([pad])
    }

    /// True when the glasses' gestures (not just the on-screen pad) are live.
    static func glassesGesturesActive(_ source: LookGestureSource?) -> Bool {
        (source as? MergedGestureSource)?.sources.contains { $0 is GlassesInputs && $0.isActive } ?? false
    }

    /// Short name for the status pill.
    static func label(_ source: LookFrameSource) -> String {
        switch source {
        case is GlassesCamera: "Glasses"
        case is PhoneCameraSource: "iPhone camera"
        default: source.name
        }
    }
}

// MARK: - Camera + overlay

/// The frame (aspect-filled to the screen), the gaze reticle while scanning, and the green
/// highlight with its price window.
private struct LookCameraOverlay: View {
    var scanner: LookScanner

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                if let image = scanner.preview {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    VStack(spacing: 10) {
                        if scanner.status == .starting { ProgressView().tint(.white) }
                        Text(scanner.isEnabled ? "Starting camera…" : "")
                            .font(DealFont.jakarta(14, .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(width: size.width, height: size.height)
                }
                // A soft vignette keeps the chrome readable on bright scenes.
                LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.6)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)

                if scanner.isEnabled, scanner.highlight == nil {
                    LookReticle(status: scanner.status)
                        .position(x: size.width / 2, y: size.height / 2)
                        .allowsHitTesting(false)
                }
                if let highlight = scanner.highlight {
                    let rect = Self.viewRect(highlight.box, frame: scanner.frameSize, in: size)
                    LookHighlightFrame(lost: scanner.highlightLost)
                        .id(highlight.id)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .animation(.linear(duration: 0.12), value: rect)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    LookPriceWindow(scanner: scanner, highlight: highlight, target: rect, bounds: size)
                        .id("window-\(highlight.id)")
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.easeOut(duration: 0.35), value: scanner.highlight?.id)
            .animation(.easeInOut(duration: 0.6), value: scanner.highlightLost)
        }
    }

    /// Normalized frame box -> view rect, for an aspect-filled frame.
    static func viewRect(_ box: CGRect, frame: CGSize, in view: CGSize) -> CGRect {
        guard frame.width > 0, frame.height > 0 else {
            return CGRect(x: box.minX * view.width, y: box.minY * view.height, width: box.width * view.width, height: box.height * view.height)
        }
        let scale = max(view.width / frame.width, view.height / frame.height)
        let dw = frame.width * scale, dh = frame.height * scale
        let ox = (view.width - dw) / 2, oy = (view.height - dh) / 2
        return CGRect(x: ox + box.minX * dw, y: oy + box.minY * dh, width: box.width * dw, height: box.height * dh)
    }
}

/// Where the head points: four faint corner ticks, with the dwell filling in as a ring.
private struct LookReticle: View {
    var status: LookScanner.Status

    var body: some View {
        let progress: Double = if case .dwelling(let p) = status { p } else { 0 }
        let identifying = status == .identifying
        ZStack {
            CornerBrackets(length: 12)
                .stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 64, height: 64)
            Circle()
                .trim(from: 0, to: identifying ? 1 : progress)
                .stroke(identifying ? Palette.green : .white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 30, height: 30)
                .opacity(progress > 0.05 || identifying ? 1 : 0)
                .animation(.linear(duration: 0.15), value: progress)
            Circle().fill(.white.opacity(0.8)).frame(width: 4, height: 4)
        }
        .accessibilityHidden(true)
    }
}

/// The green highlight: soft fill, glowing stroke, white corner brackets, and one pulse when it
/// first appears.
private struct LookHighlightFrame: View {
    var lost: Bool
    @State private var appeared = false
    @State private var ring = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Palette.green.opacity(0.10))
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Palette.green, lineWidth: 3)
                .shadow(color: Palette.green.opacity(0.9), radius: 8)
                .shadow(color: Palette.green.opacity(0.5), radius: 22)
            // The first-appearance pulse: a ring that grows and fades out.
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Palette.green, lineWidth: 2)
                .padding(ring ? -26 : 0)
                .opacity(ring ? 0 : 0.9)
            CornerBrackets(length: 22)
                .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                .padding(-8)
                .shadow(color: .black.opacity(0.35), radius: 3)
        }
        .scaleEffect(appeared ? 1 : 1.12)
        .opacity(lost ? 0.25 : appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) { appeared = true }
            withAnimation(.easeOut(duration: 1.1).delay(0.15)) { ring = true }
        }
        .accessibilityElement()
        .accessibilityIdentifier("lookHighlight")
    }
}

/// Four L-shaped corners of the rect.
private struct CornerBrackets: Shape {
    var length: CGFloat

    func path(in rect: CGRect) -> Path {
        let l = min(length, rect.width / 2, rect.height / 2)
        var p = Path()
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            p.move(to: CGPoint(x: corner.x, y: corner.y + dy * l))
            p.addLine(to: corner)
            p.addLine(to: CGPoint(x: corner.x + dx * l, y: corner.y))
        }
        return p
    }
}

// MARK: - Price window

/// The small floating window above the box (below it if there's no room), clamped on screen.
private struct LookPriceWindow: View {
    var scanner: LookScanner
    var highlight: LookHighlight
    var target: CGRect
    var bounds: CGSize
    @State private var measured: CGSize = CGSize(width: 250, height: 140)

    private let topLimit: CGFloat = 120     // below the status bar + top chrome
    private let bottomLimit: CGFloat = 200  // above the gesture pad
    private let gap: CGFloat = 18

    var body: some View {
        let width: CGFloat = highlight.expanded ? min(320, bounds.width - 32) : 250
        let h = measured.height
        let x = min(max(target.midX, width / 2 + 16), bounds.width - width / 2 - 16)
        let above = target.minY - gap - h >= topLimit
        let below = target.maxY + gap + h <= bounds.height - bottomLimit
        let y: CGFloat = above ? target.minY - gap - h / 2
            : below ? target.maxY + gap + h / 2
            : topLimit + h / 2
        let pointerX = min(max(target.midX - (x - width / 2), 28), width - 28)

        card
            .frame(width: width)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { measured = $0 }
            .overlay(alignment: above ? .bottomLeading : .topLeading) {
                if above || below {
                    Pointer()
                        .fill(Palette.surface)
                        .frame(width: 22, height: 10)
                        .rotationEffect(.degrees(above ? 0 : 180))
                        .offset(x: pointerX - 11, y: above ? 9 : -9)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            .opacity(scanner.highlightLost ? 0.35 : 1)
            .position(x: x, y: y)
            .animation(.linear(duration: 0.12), value: x)
            .animation(.linear(duration: 0.12), value: y)
            .animation(.spring(response: 0.38, dampingFraction: 0.82), value: highlight.expanded)
            .onTapGesture { scanner.handle(.select) }
            .environment(\.colorScheme, .light)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(Palette.green).frame(width: 7, height: 7)
                Text("MARKET PRICE")
                    .font(DealFont.jakarta(10, .extrabold)).kerning(1.3)
                    .foregroundStyle(Palette.greenText)
                Spacer(minLength: 4)
                if let category = highlight.identification.category {
                    Text(category.capitalized)
                        .font(DealFont.jakarta(10, .bold))
                        .foregroundStyle(Palette.mutedWarm)
                        .padding(.horizontal, 7).frame(height: 18)
                        .background(Capsule().fill(Palette.surfaceWarm))
                }
            }
            Text(highlight.identification.name ?? "")
                .font(DealFont.jakarta(14, .bold))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("lookItemName")
            priceLine
            if highlight.expanded {
                LookExpandedDetail(scanner: scanner, highlight: highlight)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                hint("hand.pinch.fill", "Pinch for details")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.surface))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(highlight.expanded ? "lookWindowExpanded" : "lookWindow")
    }

    @ViewBuilder
    private var priceLine: some View {
        if let price = highlight.price {
            Text(LookFormat.range(price) ?? "No price found")
                .font(DealFont.jakarta(LookFormat.range(price) == nil ? 18 : 30, .extrabold)).kerning(-1)
                .foregroundStyle(Palette.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
                .accessibilityIdentifier("lookPriceRange")
            if !price.summary.isEmpty {
                Text(price.summary)
                    .font(DealFont.jakarta(13, .medium))
                    .foregroundStyle(Palette.inkSoft)
                    .lineLimit(highlight.expanded ? 3 : 1)
                    .accessibilityIdentifier("lookPriceSummary")
            }
        } else if let error = scanner.priceError {
            Text(error).font(DealFont.jakarta(15, .bold)).foregroundStyle(Palette.muted)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Palette.ink)
                Text("Checking prices…").font(DealFont.jakarta(15, .bold)).foregroundStyle(Palette.muted)
            }
            .frame(height: 36)
            .accessibilityIdentifier("lookPriceLoading")
        }
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
            Text(text).font(DealFont.jakarta(11, .semibold))
        }
        .foregroundStyle(Palette.faint)
        .padding(.top, 2)
    }

    /// The little triangle that points at the item.
    private struct Pointer: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.closeSubpath()
            return p
        }
    }
}

/// The expanded window: page dots, then the range meter (Market price), the research sources,
/// or the negotiate prompt. Swipes (`.next` / `.previous`) change page.
private struct LookExpandedDetail: View {
    var scanner: LookScanner
    var highlight: LookHighlight

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Palette.divider).frame(height: 1).padding(.vertical, 2)
            HStack {
                Text(scanner.page.title.uppercased())
                    .font(DealFont.jakarta(10, .extrabold)).kerning(1.3)
                    .foregroundStyle(Palette.muted)
                Spacer()
                HStack(spacing: 5) {
                    ForEach(LookScanner.DetailPage.allCases, id: \.self) { p in
                        Capsule()
                            .fill(p == scanner.page ? Palette.ink : Palette.grabber)
                            .frame(width: p == scanner.page ? 14 : 6, height: 6)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: scanner.page)
            }
            Group {
                switch scanner.page {
                case .price: pricePage
                case .sources: sourcesPage
                case .negotiate: negotiatePage
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                hint("hand.draw.fill", "Swipe for more")
                hint("hand.pinch.fill", "Pinch to close")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lookExpanded")
    }

    @ViewBuilder
    private var pricePage: some View {
        let price = highlight.price
        HStack(spacing: 8) {
            stat(price?.priceLow.map { Money.format($0) } ?? "—", "Low")
            stat(price?.priceHigh.map { Money.format($0) } ?? "—", "High")
            stat(price.map { "\($0.sourceCount)" } ?? "—", price?.sourceCount == 1 ? "Source" : "Sources")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lookExpandedStats")
        if let low = price?.priceLow, let high = price?.priceHigh, high > low {
            LookRangeBar(low: low, high: high)
        }
    }

    @ViewBuilder
    private var sourcesPage: some View {
        if let research = scanner.research, !research.sources.isEmpty {
            VStack(spacing: 0) {
                let shown = Array(research.sources.prefix(3))
                ForEach(Array(shown.enumerated()), id: \.offset) { index, source in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.title).font(DealFont.jakarta(12, .bold)).lineLimit(1)
                            Text(source.host).font(DealFont.jakarta(11)).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let p = source.price { Text(Money.format(p)).font(DealFont.jakarta(13, .extrabold)) }
                    }
                    .padding(.vertical, 7)
                    if index < shown.count - 1 { Rectangle().fill(Palette.divider).frame(height: 1) }
                }
            }
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surfaceWarm))
        } else if scanner.researchLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Palette.ink)
                Text("Searching listings…").font(DealFont.jakarta(13, .semibold)).foregroundStyle(Palette.muted)
            }
        } else {
            Text(scanner.researchError ?? "No sources found.")
                .font(DealFont.jakarta(13)).foregroundStyle(Palette.muted)
        }
    }

    private var negotiatePage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Buying this? DEAL coaches you live, with this range as your target.")
                .font(DealFont.jakarta(13))
                .foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Button { scanner.handle(.negotiate) } label: {
                Label("Negotiate", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .buttonStyle(PillButtonStyle(kind: .ink, height: 40))
            .accessibilityIdentifier("lookNegotiateButton")
            hint("button.horizontal.top.press.fill", "Or hold the capture button")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(DealFont.jakarta(16, .extrabold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label.uppercased()).font(DealFont.jakarta(9, .bold)).kerning(1).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surfaceWarm))
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
            Text(text).font(DealFont.jakarta(11, .semibold))
        }
        .foregroundStyle(Palette.faint)
    }
}

/// Low → high bar with the midpoint ("fair") marked.
private struct LookRangeBar: View {
    var low: Int
    var high: Int

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surfaceWarm)
                    Capsule()
                        .fill(LinearGradient(colors: [Palette.green, Palette.amber], startPoint: .leading, endPoint: .trailing))
                    Circle().fill(Palette.ink).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .offset(x: g.size.width / 2 - 5)
                }
            }
            .frame(height: 8)
            HStack {
                Text("Good deal").font(DealFont.jakarta(10, .semibold)).foregroundStyle(Palette.greenText)
                Spacer()
                Text("Fair \(Money.format((low + high) / 2))").font(DealFont.jakarta(10, .bold))
                Spacer()
                Text("Pricey").font(DealFont.jakarta(10, .semibold)).foregroundStyle(Palette.mutedWarm)
            }
        }
    }
}

enum LookFormat {
    /// "$25 – $35", one bound alone, or nil when the backend found no price.
    static func range(_ price: LookPrice) -> String? {
        switch (price.priceLow, price.priceHigh) {
        case let (l?, h?) where l == h: Money.format(l)
        case let (l?, h?): "\(Money.format(min(l, h))) – \(Money.format(max(l, h)))"
        case let (l?, nil): Money.format(l)
        case let (nil, h?): Money.format(h)
        default: nil
        }
    }
}

// MARK: - Chrome pieces

/// "Glasses · Scanning": the frame source and what the scanner is doing.
private struct LookStatusPill: View {
    var scanner: LookScanner

    var body: some View {
        HStack(spacing: 8) {
            indicator
            Text(LookSources.label(scanner.frames))
                .font(DealFont.jakarta(13, .bold))
            Text("·").foregroundStyle(.white.opacity(0.5))
            Text(scanner.notice ?? scanner.status.label)
                .font(DealFont.jakarta(13, .semibold))
                .foregroundStyle(scanner.notice == nil ? .white.opacity(0.75) : Palette.liveDot)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Capsule().fill(.ultraThinMaterial))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lookStatus")
    }

    @ViewBuilder
    private var indicator: some View {
        switch scanner.status {
        case .dwelling(let progress):
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 10, height: 10)
        case .identifying:
            ProgressView().controlSize(.mini).tint(.white)
        default:
            Circle().fill(dotColor).frame(width: 8, height: 8)
        }
    }

    private var dotColor: Color {
        switch scanner.status {
        case .off: .white.opacity(0.4)
        case .showing: Palette.green
        case .failed: Palette.liveDot
        default: scanner.notice == nil ? .white : Palette.liveDot
        }
    }
}

/// The Look on/off switch (off by default).
private struct LookToggle: View {
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("Look").font(DealFont.jakarta(13, .bold))
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Palette.green : .white.opacity(0.25))
                    Circle().fill(.white).frame(width: 18, height: 18).padding(3)
                }
                .frame(width: 42, height: 24)
            }
            .foregroundStyle(.white)
            .padding(.leading, 14).padding(.trailing, 8)
            .frame(height: 40)
            .background(Capsule().fill(.ultraThinMaterial))
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Look")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityIdentifier("lookToggle")
    }
}

/// The glasses gestures as buttons, for when no glasses are attached (and the demo).
private struct LookGesturePad: View {
    var scanner: LookScanner
    var pad: PhoneGestureSource
    var busy: Bool

    private var active: Bool { scanner.highlight != nil && !busy }

    var body: some View {
        VStack(spacing: 10) {
            if let demo = scanner.frames as? LookDemoFrameSource, scanner.isEnabled {
                Button { demo.lookingAway ? demo.lookBack() : demo.lookAway() } label: {
                    Label(demo.lookingAway ? "Look back" : "Look away",
                          systemImage: demo.lookingAway ? "arrow.uturn.left" : "arrow.right")
                        .font(DealFont.jakarta(12, .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Capsule().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lookDemoPan")
            }
            HStack(spacing: 0) {
                pad("chevron.left", "Back", .previous)
                pad("xmark", "Dismiss", .dismiss)
                pad("hand.pinch.fill", "Pinch", .select, primary: true)
                pad("bubble.left.and.bubble.right.fill", "Negotiate", .negotiate)
                pad("chevron.right", "Next", .next)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.ultraThinMaterial))
            Text(LookSources.glassesGesturesActive(scanner.gestures) ? "Neural Band connected · buttons mirror your gestures"
                 : "No glasses? These send the same gestures.")
                .font(DealFont.jakarta(11, .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.bottom, 6)
    }

    private func pad(_ symbol: String, _ label: String, _ gesture: LookGesture, primary: Bool = false) -> some View {
        Button { pad.send(gesture) } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: primary ? 20 : 16, weight: .bold))
                    .foregroundStyle(primary ? Palette.ink : .white)
                    .frame(width: primary ? 56 : 44, height: primary ? 56 : 44)
                    .background(Circle().fill(primary ? Palette.green : .white.opacity(0.14)))
                Text(label).font(DealFont.jakarta(10, .semibold)).foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(active ? 1 : 0.4)
        .disabled(!active)
        .accessibilityLabel(label)
        .accessibilityIdentifier("lookGesture-\(gesture)")
    }
}
