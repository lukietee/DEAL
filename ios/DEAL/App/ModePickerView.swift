import SwiftUI

/// Start screen: I'm Buying / I'm Selling + glasses-connected status dot.
struct ModePickerView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                VStack(spacing: 6) {
                    Text("DEAL")
                        .font(.system(size: 56, weight: .black, design: .rounded))
                    Text("Negotiate. Lock it in. Pay exactly that.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                ModeButton(title: "I'm Buying", subtitle: "Coach me and protect my payment",
                           symbol: "cart.fill", tint: Theme.accent) {
                    model.mode = .buyer
                }
                ModeButton(title: "I'm Selling", subtitle: "Join a buyer's session and take payment",
                           symbol: "creditcard.and.123", tint: .orange) {
                    model.mode = .seller
                }
                Spacer()
                statusRow
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .dealTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .task { await model.checkBackend() }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                StatusDot(color: model.glasses.isConnected ? .green : .gray)
                Text(model.glasses.isConnected ? "Glasses: \(model.glasses.name)" : "Glasses not connected")
            }
            HStack(spacing: 6) {
                StatusDot(color: model.backendReachable == nil ? .gray : (model.backendReachable == true ? .green : .red))
                Text(model.backendReachable == false ? "Backend offline" : "Backend")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .onTapGesture { Task { await model.checkBackend() } }
    }
}

private struct ModeButton: View {
    var title: String
    var subtitle: String
    var symbol: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol).font(.system(size: 30, weight: .semibold)).frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.weight(.bold))
                    Text(subtitle).font(.subheadline).opacity(0.85)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.headline)
            }
            .foregroundStyle(.white)
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 110)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(tint.gradient))
        }
        .buttonStyle(.plain)
    }
}
