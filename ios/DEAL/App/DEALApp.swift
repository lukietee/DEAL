import SwiftUI

@main
struct DEALApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
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
