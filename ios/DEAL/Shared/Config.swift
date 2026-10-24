import Foundation

/// Static defaults (Section 12.4). Runtime-editable values live in `AppSettings`
/// (Settings screen), which falls back to these.
///
/// No secret keys belong in this file. The Supabase anon key is a public,
/// read-only key; the service-role key must never appear in the iOS app.
enum Config {
    /// Simulator can reach the Mac via localhost. On a device use the ngrok URL
    /// (or the Mac's LAN IP) via Settings.
    static let defaultBackendURL = "http://localhost:3000"

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
