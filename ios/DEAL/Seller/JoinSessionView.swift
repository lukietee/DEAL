import SwiftUI

/// S1. Join Session: scan the buyer's QR code or enter the join code.
struct JoinSessionView: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""
    @State private var showScanner = false
    @State private var isJoining = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "qrcode.viewfinder").font(.system(size: 64)).foregroundStyle(.orange)
            Text("Join the buyer's session").font(.title2.weight(.bold))
            Text("Scan the QR code on the buyer's phone, or type the join code.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

            Button {
                showScanner = true
            } label: {
                Label("Scan QR code", systemImage: "camera.viewfinder")
            }
            .buttonStyle(PrimaryButtonStyle(tint: .orange))

            HStack {
                TextField("Join code", text: $code)
                    .font(.title2.monospaced())
                    .multilineTextAlignment(.center)
                    .dealCodeEntry()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await join(code) } }
                Button("Join") { Task { await join(code) } }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(JoinCode.parse(code) == nil || isJoining)
            }

            if isJoining { ProgressView() }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(24)
        .navigationTitle("Seller")
        .dealInlineTitle()
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
