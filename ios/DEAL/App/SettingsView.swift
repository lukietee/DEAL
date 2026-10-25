import SwiftUI

/// Settings: backend URL (ngrok tonight), optional Supabase Realtime, glasses test cue,
/// delete sessions.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showTeleprompter = false
    @State private var confirmDelete = false
    @State private var confirmDeleteAll = false
    @State private var deleteMessage: String?

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section {
                    TextField("http://localhost:3000", text: $settings.backendURLString)
                        .dealURLEntry()
                    HStack {
                        Button("Test connection") { Task { await model.checkBackend() } }
                        Spacer()
                        switch model.backendReachable {
                        case .some(true): Label("Reachable", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .some(false): Label("Unreachable", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                        case .none: ProgressView()
                        }
                    }
                } header: {
                    Text("Backend URL")
                } footer: {
                    Text("Simulator: http://localhost:3000. iPhone: your ngrok https URL or http://<Mac LAN IP>:3000. Using \(model.settings.backendURL.absoluteString).")
                }

                Section {
                    TextField("https://<project>.supabase.co", text: $settings.supabaseURLString)
                        .dealURLEntry()
                    TextField("Anon key (public, read-only)", text: $settings.supabaseAnonKey)
                        .dealURLEntry()
                } header: {
                    Text("Supabase Realtime (optional)")
                } footer: {
                    Text(model.settings.supabaseConfig == nil
                         ? "Empty: phones sync by polling the backend every second (works with the in-memory mock backend)."
                         : "Realtime enabled for new sessions. Never paste the service-role key here.")
                }

                Section {
                    MetaGlassesSettingsRows(glasses: model.metaGlasses)
                    HStack {
                        StatusDot(color: .green)
                        Text(model.teleprompter.name)
                        Spacer()
                        Text("Always on").foregroundStyle(.secondary)
                    }
                    Button("Send test cue") {
                        model.glasses.show(GlassesCue(text: "Redirect to total price", detail: "$489/mo × 72 = $35,208",
                                                      status: .yellow, currentOffer: 3_540_000, target: 3_450_000,
                                                      sourceID: "test-\(Date().timeIntervalSince1970)"))
                        showTeleprompter = true
                    }
                    Button("Open teleprompter") { showTeleprompter = true }
                } header: {
                    Text("Glasses")
                } footer: {
                    Text("Cues go to the phone teleprompter and, when connected, the Meta Ray-Ban Display. Needs Meta AI with Developer Mode on (see ios/README.md).")
                }

                Section {
                    Button("Leave current session", role: .destructive) { confirmDelete = true }
                        .disabled(model.activeStore == nil)
                    Button("Delete all sessions", role: .destructive) { confirmDeleteAll = true }
                    Button("Reset settings to defaults") { model.settings.resetToDefaults() }
                } footer: {
                    Text(deleteMessage ?? "Delete all sessions calls DELETE /sessions on the backend (both phones lose their session).")
                }
            }
            .navigationTitle("Settings")
            .dealInlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
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
    }
}
