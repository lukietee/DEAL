import SwiftUI

/// S1. Join Session: scan the buyer's QR code or enter the join code.
struct JoinSessionView: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""
    @State private var showScanner = false
    @State private var isJoining = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            HeroScaffold(heroBottomPadding: 80) {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        SellerExitButton(size: 48)
                        Spacer()
                        Chip(text: "Seller", eyebrow: true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Join the buyer's\nsession")
                            .font(DealFont.title)
                            .kerning(-1.1)
                            .lineSpacing(-2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Scan the QR code on the buyer's phone, or type the join code.")
                            .font(DealFont.jakarta(15))
                            .lineSpacing(3)
                            .foregroundStyle(Palette.mutedWarm)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } content: {
                codeField
                    .padding(.top, -32)
                    .padding(.trailing, 20)

                if isJoining {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let error {
                    Text(error)
                        .font(DealFont.caption)
                        .foregroundStyle(Palette.red)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 8)
                }

                SectionHeader(title: "Or scan it")
                    .padding(.top, 8)
                scanCard
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .background(alignment: .top) { Palette.sand.frame(height: 200).ignoresSafeArea(edges: .top) }
        .dealPage()
        .sheet(isPresented: $showScanner) {
            QRScannerSheet { scanned in
                showScanner = false
                if let parsed = JoinCode.parse(scanned) {
                    code = parsed
                    Task { await join(parsed) }
                }
            }
        }
    }

    private var codeField: some View {
        HStack(spacing: 8) {
            TextField("Join code", text: $code)
                .font(DealFont.mono(26, .semibold))
                .kerning(7)
                .dealCodeEntry()
                .onSubmit { Task { await join(code) } }
                .accessibilityIdentifier("Join code")
            Button("Join") { Task { await join(code) } }
                .buttonStyle(PillButtonStyle(kind: .sand, height: 50, fullWidth: false))
                .disabled(JoinCode.parse(code) == nil || isJoining)
                .opacity(JoinCode.parse(code) == nil || isJoining ? 0.5 : 1)
        }
        .padding(.leading, 24)
        .padding(.trailing, 7)
        .frame(height: 64)
        .background(Capsule().fill(Palette.surface).shadow(color: .black.opacity(0.12), radius: 9, y: 6))
    }

    private var scanCard: some View {
        Button { showScanner = true } label: {
            VStack(spacing: 22) {
                ZStack {
                    ViewfinderCorners()
                        .stroke(Palette.ink, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                        .frame(width: 140, height: 140)
                    Image(systemName: "qrcode")
                        .font(.system(size: 50, weight: .regular))
                }
                .accessibilityHidden(true)
                HStack(spacing: 10) {
                    Image(systemName: "camera.fill").font(.system(size: 16, weight: .semibold))
                    Text("Scan QR code")
                }
                .font(DealFont.jakarta(16, .bold))
                .padding(.horizontal, 26)
                .frame(height: 52)
                .background(Capsule().fill(Palette.sand))
            }
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, minHeight: 280)
            .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(Palette.surface))
            .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scan QR code")
    }

    private func join(_ raw: String) async {
        guard let parsed = JoinCode.parse(raw), !isJoining else { return }
        isJoining = true
        defer { isJoining = false }
        do {
            let session = try await model.api.joinSession(code: parsed)
            error = nil
            _ = model.makeStore(role: .seller, session: session)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Four rounded viewfinder corners (the S1 scan target).
struct ViewfinderCorners: Shape {
    var length: CGFloat = 0.26
    var radius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let l = min(rect.width, rect.height) * length
        let r = radius
        var p = Path()
        // top-left
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + l))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        // top-right
        p.move(to: CGPoint(x: rect.maxX - l, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        // bottom-right
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        // bottom-left
        p.move(to: CGPoint(x: rect.minX + l, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return p
    }
}
