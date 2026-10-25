import SwiftUI

@main
struct DEALApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
                // Meta AI calls back on deal://…?metaWearablesAction=… after registration.
                .onOpenURL { url in model.metaGlasses.handleURL(url) }
                #if DEBUG
                // Mock glasses: float MockDeviceKit's render of the glasses display over the app,
                // so a scripted negotiation in the Simulator shows exactly what the glasses get.
                .overlay(alignment: .bottomTrailing) {
                    if let preview = model.metaGlasses.mockPreview {
                        MockGlassesPreview(display: preview)
                            .frame(width: 240, height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.3)))
                            .padding(.trailing, 12).padding(.bottom, 90)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("mockGlassesOverlay")
                    }
                }
                #endif
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-DEALMockGlasses") {
                        await model.metaGlasses.enableMockGlasses()
                        return
                    }
                    #endif
                    model.metaGlasses.autoConnectIfNeeded()
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.mode {
        case nil:
            ModePickerView()
        case .buyer:
            BuyerFlowView()
        case .seller:
            SellerFlowView()
        }
    }
}
