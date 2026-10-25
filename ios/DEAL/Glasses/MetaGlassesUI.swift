import SwiftUI
#if DEBUG
import MWDATMockDevice
#endif

// SwiftUI helpers for `MetaGlassesDisplay` (kept out of MetaGlassesDisplay.swift so the
// MWDATDisplay `Text` / `Image` names don't clash with SwiftUI's).

extension MetaGlassesStatus {
    var color: Color {
        switch self {
        case .connected: .green
        case .failed: .red
        case .off: .gray
        default: .yellow
        }
    }
}

/// Settings → Glasses: connection status, Connect / Disconnect, debug mock preview.
struct MetaGlassesSettingsRows: View {
    var glasses: MetaGlassesDisplay

    var body: some View {
        HStack {
            StatusDot(color: glasses.status.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(glasses.name)
                if let device = glasses.deviceName {
                    Text(glasses.isMock ? "\(device) (mock)" : device)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if glasses.status.isBusy { ProgressView().padding(.trailing, 4) }
            Text(glasses.status.label).foregroundStyle(.secondary)
        }
        if glasses.wantsConnection {
            Button("Disconnect glasses", role: .destructive) { glasses.disconnect() }
        } else {
            Button("Connect glasses") { glasses.connect() }
        }
        if let error = glasses.lastError {
            Text(error).font(.footnote).foregroundStyle(.red)
        }
        #if DEBUG
        Toggle("Mock glasses (phone preview)", isOn: Binding(
            get: { glasses.isMock },
            set: { on in
                if on { Task { await glasses.enableMockGlasses() } } else { glasses.disableMockGlasses() }
            }))
        #endif
    }
}

#if DEBUG
/// MockDeviceKit's render of the simulated glasses display.
struct MockGlassesPreview: UIViewRepresentable {
    let display: any MockDisplayKit

    func makeUIView(context: Context) -> UIView { display.createPreviewView() }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
