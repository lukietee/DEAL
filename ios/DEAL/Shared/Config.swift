import Foundation

/// Static defaults (Section 12.4). Runtime-editable values live in `AppSettings`
/// (Settings screen), which falls back to these.
///
/// No secret keys belong in this file. The Supabase anon key is a public,
/// read-only key; the service-role key must never appear in the iOS app.
enum Config {
    /// Simulator can reach the Mac via localhost. A device build uses `DEAL_BACKEND_URL`
    /// (Info.plist `DEALBackendURL`, e.g. `xcodebuild ... DEAL_BACKEND_URL=http://192.168.1.20:3000`)
    /// when set; otherwise set the Mac's LAN IP or an https tunnel URL in Settings.
    static let defaultBackendURL: String = {
        #if targetEnvironment(simulator)
        return "http://localhost:3000"
        #else
        let built = (Bundle.main.object(forInfoDictionaryKey: "DEALBackendURL") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return built.hasPrefix("http") ? built : "http://localhost:3000"
        #endif
    }()

    /// Leave empty to use polling (backend in-memory mock mode has no Supabase).
    static let defaultSupabaseURL = ""
    static let defaultSupabaseAnonKey = ""

    /// Polling fallback cadence for `GET /sessions/:id`.
    static let pollInterval: TimeInterval = 1.0

    /// When Supabase Realtime is active we still refresh occasionally as a safety net.
    static let realtimeSafetyPollInterval: TimeInterval = 5.0

    /// Delay between scripted lines for `POST /sessions/:id/script/play`.
    /// `nil` lets the backend use each line's own `delay_ms`.
    static let scriptIntervalMs: Int? = nil

    static let requestTimeout: TimeInterval = 20
}
