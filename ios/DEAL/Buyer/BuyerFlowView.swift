import SwiftUI

/// Screens pushed on top of B1 Home.
enum BuyerRoute: Hashable {
    /// B2
    case newNegotiation
    /// B7 list
    case history
    /// B7 Deal Detail
    case deal(Session)
}

/// Buyer mode container. B1 Home is the root (B2 and B7 push on top of it). While a session is
/// active it takes over the root and routes by `SessionState.buyerPhase` (B3 -> B4 -> B6), with B5
/// presented over everything whenever a charge is blocked. "Home" steps back to B1 without ending
/// the session; B1's active-session card resumes it.
struct BuyerFlowView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [BuyerRoute] = []
    @State private var showHome = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let store = model.activeStore, store.role == .buyer, !showHome {
                    BuyerSessionView(store: store)
                        .toolbar {
                            ToolbarItem(placement: .dealLeading) {
                                Button { showHome = true } label: {
                                    Label("Home", systemImage: "chevron.backward")
                                }
                            }
                        }
                } else {
                    BuyerHomeView(path: $path, onResume: resume)
                        .toolbar {
                            ToolbarItem(placement: .dealLeading) {
                                Button { model.exitToModePicker() } label: {
                                    Label("Exit", systemImage: "chevron.backward")
                                }
                            }
                        }
                }
            }
            .navigationDestination(for: BuyerRoute.self) { route in
                switch route {
                case .newNegotiation: NewNegotiationView()
                case .history: PurchaseHistoryView()
                case .deal(let session): DealDetailView(session: session)
                }
            }
        }
        // A new session (B2 Start Session, or resuming one from the backend) or the end of one
        // (B6 Done) resets the stack so the root shows the right screen.
        .onChange(of: model.activeStore?.session.id) {
            path = []
            showHome = false
        }
    }

    /// B1 active-session card: `nil` resumes this phone's session; a backend session re-attaches.
    private func resume(_ session: Session?) {
        if let session, model.activeStore?.session.id != session.id {
            _ = model.makeStore(role: .buyer, session: session)
        }
        path = []
        showHome = false
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
