import Foundation
import Observation

/// User-editable configuration, persisted in UserDefaults. Edited in Settings.
@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let backendURL = "deal.backendURL"
        static let supabaseURL = "deal.supabaseURL"
        static let supabaseAnonKey = "deal.supabaseAnonKey"
    }

    private let defaults: UserDefaults

    var backendURLString: String {
        didSet { defaults.set(backendURLString, forKey: Keys.backendURL) }
    }
    var supabaseURLString: String {
        didSet { defaults.set(supabaseURLString, forKey: Keys.supabaseURL) }
    }
    var supabaseAnonKey: String {
        didSet { defaults.set(supabaseAnonKey, forKey: Keys.supabaseAnonKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        backendURLString = defaults.string(forKey: Keys.backendURL) ?? Config.defaultBackendURL
        supabaseURLString = defaults.string(forKey: Keys.supabaseURL) ?? Config.defaultSupabaseURL
        supabaseAnonKey = defaults.string(forKey: Keys.supabaseAnonKey) ?? Config.defaultSupabaseAnonKey
    }

    /// Trims whitespace and trailing slashes; falls back to the default if invalid.
    var backendURL: URL {
        Self.normalizedURL(backendURLString) ?? URL(string: Config.defaultBackendURL)!
    }

    /// Non-nil only when both URL and anon key are set -> Realtime; otherwise polling.
    var supabaseConfig: (url: URL, anonKey: String)? {
        let key = supabaseAnonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let url = Self.normalizedURL(supabaseURLString) else { return nil }
        return (url, key)
    }

    func resetToDefaults() {
        backendURLString = Config.defaultBackendURL
        supabaseURLString = Config.defaultSupabaseURL
        supabaseAnonKey = Config.defaultSupabaseAnonKey
    }

    nonisolated static func normalizedURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}
