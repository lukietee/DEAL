import Foundation
import Observation

enum AppMode: String, Sendable { case buyer, seller }

/// App-wide state: settings, the glasses display, the chosen mode, and the active session.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    /// Phone fallback / projector mirror. Always receives every cue.
    let teleprompter: PhoneTeleprompterDisplay
    /// Ray-Ban Meta Display (Meta Wearables SDK). Connect from the mode picker or Settings.
    let metaGlasses: MetaGlassesDisplay
    /// What sessions push cues to: the teleprompter AND the Meta glasses.
    let glassesFanOut: GlassesFanOut
    var glasses: GlassesDisplay { glassesFanOut }

    var mode: AppMode?
    private(set) var activeStore: SessionStore?
    private(set) var backendReachable: Bool?

    init(settings: AppSettings? = nil) {
        self.settings = settings ?? AppSettings()
        let teleprompter = PhoneTeleprompterDisplay()
        let metaGlasses = MetaGlassesDisplay()
        self.teleprompter = teleprompter
        self.metaGlasses = metaGlasses
        self.glassesFanOut = GlassesFanOut(phone: teleprompter, meta: metaGlasses)
    }

    var api: APIClient { APIClient(baseURL: settings.backendURL) }

    func makeStore(role: Speaker, session: Session) -> SessionStore {
        activeStore?.stopAll()
        let api = self.api
        let sync = SessionSyncFactory.make(api: api, supabase: settings.supabaseConfig)
        let store = SessionStore(role: role, session: session, api: api, sync: sync,
                                 glasses: role == .buyer ? glasses : nil)
        activeStore = store
        store.startSync()
        return store
    }

    func endSession() {
        activeStore?.stopAll()
        activeStore = nil
        glasses.clear()
    }

    func exitToModePicker() {
        endSession()
        mode = nil
    }

    func checkBackend() async {
        backendReachable = nil
        backendReachable = (try? await api.health()) ?? false
    }
}
