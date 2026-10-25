import SwiftUI

/// A1 Settings ("demo operator tools"): backend URL, optional Supabase Realtime, glasses
/// connection + test cue, delete sessions. Deliberately cooler than the rest of the app:
/// #F3F2EE page, white bordered cards, mono inputs.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showTeleprompter = false
    @State private var confirmDelete = false
    @State private var confirmDeleteAll = false
    @State private var deleteMessage: String?

    var body: some View {
        @Bindable var settings = model.settings
        ScrollView {
            VStack(spacing: 24) {
                header

                OpsSection(title: "Profile", footer: "Shown in the greeting on the start screen.") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Display name").font(DealFont.jakarta(13)).foregroundStyle(Ops.secondary)
                        TextField(AppSettings.defaultDisplayName, text: $settings.displayName)
                            .autocorrectionDisabled()
                            .font(DealFont.jakarta(16))
                            .padding(.horizontal, 12)
                            .frame(height: 44)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ops.inputFill))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ops.border, lineWidth: 1))
                            .accessibilityLabel("Display name")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }

                OpsSection(title: "Demo",
                           footer: "Off: DEAL starts empty and works for any item (paste a link, the listing text or a screenshot; live mic; real market research). On: the stage shortcuts come back: the demo bike listing loads on its own, Car demo / Use demo values, Play script and Scripted mode, Use sample observation, the terminal's gas fee / protection package prefills and the illustrative comparables.") {
                    Toggle("Demo shortcuts", isOn: $settings.demoShortcuts)
                        .font(DealFont.jakarta(16))
                        .tint(Ops.green)
                        .opsRow()
                        .accessibilityIdentifier("demoShortcutsToggle")
                }

                OpsSection(title: "Backend",
                           footer: "Simulator: http://localhost:3000. iPhone: your ngrok https URL or http://<Mac LAN IP>:3000. Using \(model.settings.backendURL.absoluteString).") {
                    VStack(alignment: .leading, spacing: 12) {
                        OpsField(label: "Backend URL", placeholder: "http://localhost:3000", text: $settings.backendURLString)
                        HStack {
                            Button("Test connection") { Task { await model.checkBackend() } }
                                .buttonStyle(OpsButtonStyle(height: 40))
                            Spacer()
                            reachability
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }

                OpsSection(title: "Supabase Realtime · optional",
                           footer: model.settings.supabaseConfig == nil
                           ? "Empty: phones sync by polling the backend every second (works with the in-memory mock backend)."
                           : "Realtime enabled for new sessions. Never paste the service-role key here.") {
                    VStack(alignment: .leading, spacing: 12) {
                        OpsField(label: "Project URL", placeholder: "https://<project>.supabase.co", text: $settings.supabaseURLString)
                        OpsField(label: "Anon key (public, read-only)", placeholder: "eyJhbGciOi…", text: $settings.supabaseAnonKey)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }

                OpsSection(title: "Glasses",
                           footer: "Cues go to the phone teleprompter and, when connected, the Meta Ray-Ban Display. Needs Meta AI with Developer Mode on (see ios/README.md).") {
                    VStack(spacing: 0) {
                        GlassesConnectionRows(glasses: model.metaGlasses)
                        HStack {
                            Text(model.teleprompter.name).font(DealFont.jakarta(16))
                            Spacer()
                            HStack(spacing: 6) {
                                Circle().fill(Ops.green).frame(width: 7, height: 7)
                                Text("Always on")
                            }
                            .font(DealFont.jakarta(14, .medium))
                            .foregroundStyle(Ops.greenText)
                        }
                        .opsRow()
                        OpsDivider()
                        HStack(spacing: 8) {
                            Button("Send test cue") {
                                model.glasses.show(GlassesCue(text: "Redirect to total price", detail: "$489/mo × 72 = $35,208",
                                                              status: .yellow, currentOffer: 3_540_000, target: 3_450_000,
                                                              sourceID: "test-\(Date().timeIntervalSince1970)"))
                                showTeleprompter = true
                            }
                            .buttonStyle(OpsButtonStyle(fullWidth: true))
                            Button("Open teleprompter") { showTeleprompter = true }
                                .buttonStyle(OpsButtonStyle(fullWidth: true))
                        }
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
                    }
                }

                OpsSection(title: "Danger zone", titleColor: Ops.danger, border: Ops.dangerBorder,
                           footer: deleteMessage ?? "Delete all sessions calls DELETE /sessions on the backend (both phones lose their session).") {
                    VStack(spacing: 0) {
                        DangerRow(title: "Leave current session") { confirmDelete = true }
                            .disabled(model.activeStore == nil)
                        OpsDivider()
                        DangerRow(title: "Delete all sessions") { confirmDeleteAll = true }
                        OpsDivider()
                        DangerRow(title: "Reset settings to defaults") { model.settings.resetToDefaults() }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .font(DealFont.jakarta(16))
        .foregroundStyle(Ops.ink)
        .tint(Ops.ink)
        .background(Ops.page.ignoresSafeArea())
        .presentationBackground(Ops.page)
        .confirmationDialog("Leave the current session on this phone?", isPresented: $confirmDelete) {
            Button("Leave session", role: .destructive) { model.exitToModePicker(); dismiss() }
        }
        .confirmationDialog("Delete every session on the backend?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete all sessions", role: .destructive) {
                Task {
                    do {
                        try await model.api.deleteAllSessions()
                        model.exitToModePicker()
                        deleteMessage = "All sessions deleted."
                    } catch {
                        deleteMessage = error.localizedDescription
                    }
                }
            }
        }
        .dealFullScreenCover(isPresented: $showTeleprompter) {
            TeleprompterView(display: model.teleprompter)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Capsule().fill(Color(hex: 0xCFCCC4)).frame(width: 36, height: 5)
            ZStack {
                Text("Settings").font(DealFont.jakarta(17, .semibold))
                    .accessibilityAddTraits(.isHeader)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .font(DealFont.jakarta(15, .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 44)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ops.ink))
                        .buttonStyle(.plain)
                }
            }
            Text("Demo operator tools · not shown to buyers or sellers")
                .font(DealFont.jakarta(12))
                .foregroundStyle(Ops.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: 0xE9E7E1)))
        }
    }

    @ViewBuilder
    private var reachability: some View {
        switch model.backendReachable {
        case .some(true):
            HStack(spacing: 6) {
                Circle().fill(Ops.green).frame(width: 8, height: 8)
                Text("Reachable")
            }
            .font(DealFont.jakarta(14, .semibold))
            .foregroundStyle(Ops.greenText)
        case .some(false):
            HStack(spacing: 6) {
                Circle().fill(Ops.danger).frame(width: 8, height: 8)
                Text("Unreachable")
            }
            .font(DealFont.jakarta(14, .semibold))
            .foregroundStyle(Ops.danger)
        case .none:
            ProgressView()
        }
    }
}

// MARK: - Operator-tools styling (A1 only)

private enum Ops {
    static let page = Color(hex: 0xF3F2EE)
    static let card = Color.white
    static let border = Color(hex: 0xE4E2DC)
    static let rowDivider = Color(hex: 0xEEECE6)
    static let inputFill = Color(hex: 0xFAFAF8)
    static let ink = Color(hex: 0x111110)
    static let secondary = Color(hex: 0x5C5B57)
    static let caption = Color(hex: 0x6E6C67)
    static let green = Color(hex: 0x1F9D55)
    static let greenText = Color(hex: 0x137A40)
    static let offDot = Color(hex: 0xA3A19B)
    static let danger = Color(hex: 0xB42318)
    static let dangerBorder = Color(hex: 0xF3C9C4)
}

private struct OpsSection<Content: View>: View {
    var title: String
    var titleColor: Color = Ops.caption
    var border: Color = Ops.border
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(DealFont.jakarta(12, .semibold))
                .kerning(0.7)
                .foregroundStyle(titleColor)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Ops.card))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(border, lineWidth: 1))
            if let footer {
                Text(footer)
                    .font(DealFont.jakarta(12))
                    .lineSpacing(3)
                    .foregroundStyle(Ops.caption)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct OpsField: View {
    var label: String
    var placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(DealFont.jakarta(13)).foregroundStyle(Ops.secondary)
            TextField(placeholder, text: $text)
                .dealURLEntry()
                .font(DealFont.mono(14))
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ops.inputFill))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ops.border, lineWidth: 1))
                .accessibilityLabel(label)
        }
    }
}

private struct OpsButtonStyle: ButtonStyle {
    var height: CGFloat = 44
    var fullWidth = false
    var filled = false
    var textColor: Color = Ops.ink
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DealFont.jakarta(14, .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(filled ? .white : textColor)
            .padding(.horizontal, 14)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(filled ? Ops.ink : Ops.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(filled ? .clear : Ops.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.4))
    }
}

private struct OpsDivider: View {
    var body: some View { Rectangle().fill(Ops.rowDivider).frame(height: 1) }
}

private extension View {
    func opsRow() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
    }
}

private struct DangerRow: View {
    var title: String
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(role: .destructive, action: action) {
            Text(title)
                .font(DealFont.jakarta(16))
                .foregroundStyle(Ops.danger.opacity(isEnabled ? 1 : 0.4))
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Meta Ray-Ban Display status + Connect / Disconnect + (debug) mock preview toggle.
/// Same behaviour as `MetaGlassesSettingsRows`, laid out for the A1 card.
private struct GlassesConnectionRows: View {
    var glasses: MetaGlassesDisplay

    private var dot: Color {
        switch glasses.status {
        case .connected: Ops.green
        case .failed: Ops.danger
        case .off: Ops.offDot
        default: Palette.amber
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(glasses.name).font(DealFont.jakarta(16, .medium))
                HStack(spacing: 6) {
                    Circle().fill(dot).frame(width: 7, height: 7)
                    Text(glasses.status.label)
                    if let device = glasses.deviceName {
                        Text("· " + (glasses.isMock ? "\(device) (mock)" : device)).lineLimit(1)
                    }
                }
                .font(DealFont.jakarta(13))
                .foregroundStyle(Ops.secondary)
            }
            Spacer(minLength: 8)
            if glasses.status.isBusy { ProgressView() }
            if glasses.wantsConnection {
                Button("Disconnect") { glasses.disconnect() }
                    .buttonStyle(OpsButtonStyle(height: 40, textColor: Ops.danger))
            } else {
                Button("Connect") { glasses.connect() }
                    .buttonStyle(OpsButtonStyle(height: 40, filled: true))
            }
        }
        .opsRow()
        if let error = glasses.lastError {
            Text(error)
                .font(DealFont.jakarta(13))
                .foregroundStyle(Ops.danger)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        OpsDivider()
        #if DEBUG
        Toggle("Mock glasses (phone preview)", isOn: Binding(
            get: { glasses.isMock },
            set: { on in
                if on { Task { await glasses.enableMockGlasses() } } else { glasses.disableMockGlasses() }
            }))
            .font(DealFont.jakarta(16))
            .tint(Ops.green)
            .opsRow()
        OpsDivider()
        #endif
    }
}
