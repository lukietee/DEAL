import SwiftUI

/// Buyer mode container: B2 until a session exists, then routes by `SessionState.buyerPhase`
/// (B3 -> B4 -> B6), with B5 presented over everything whenever a charge is blocked.
struct BuyerFlowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if let store = model.activeStore, store.role == .buyer {
                    BuyerSessionView(store: store)
                } else {
                    NewNegotiationView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .dealLeading) {
                    Button { model.exitToModePicker() } label: {
                        Label("Exit", systemImage: "chevron.backward")
                    }
                }
            }
        }
    }
}

struct BuyerSessionView: View {
    @Environment(AppModel.self) private var model
    var store: SessionStore
    /// Lets the buyer step back from B4 to B3 while the agreement is still a draft.
    @State private var showLiveOverride = false
    @State private var alertRequest: PaymentRequest?
    @State private var handledAlertIDs: Set<String> = []

    var body: some View {
        let state = store.state
        VStack(spacing: 0) {
            if let error = store.bannerMessage {
                ErrorBanner(message: error) { store.clearError() }.padding(.top, 6)
            }
            switch state.buyerPhase {
            case .live:
                LiveSessionView(store: store)
            case .agreement:
                if showLiveOverride, state.agreement?.isLocked == false {
                    LiveSessionView(store: store, onBackToAgreement: { showLiveOverride = false })
                } else {
                    AgreementReviewView(store: store, onKeepNegotiating: { showLiveOverride = true })
                }
            case .receipt:
                ReceiptView(store: store)
            }
        }
        .animation(.default, value: state.buyerPhase)
        .onChange(of: state.blockedRequestAwaitingBuyer?.id, initial: true) { _, newID in
            guard let newID, !handledAlertIDs.contains(newID),
                  let req = store.state.blockedRequestAwaitingBuyer else { return }
            Platform.haptic(.error)
            alertRequest = req
        }
        .onChange(of: state.agreement?.id) { showLiveOverride = false }
        .dealFullScreenCover(item: $alertRequest) { req in
            ChargeAlertView(store: store, request: req) {
                handledAlertIDs.insert(req.id)
                alertRequest = nil
            }
        }
    }
}
