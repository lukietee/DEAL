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
        static let demoShortcuts = "deal.demoShortcuts"
        static let displayName = "deal.displayName"
    }

    /// Launch argument that forces demo shortcuts on for this run (UI tests, venue fallback).
    nonisolated static let demoShortcutsLaunchArgument = "-DEALDemoShortcuts"
    nonisolated static let defaultDisplayName = "Lucas"

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
    /// Off (default): the app works for any item, with no canned content. On: the demo
    /// shortcuts (auto-loaded bike listing, Car demo, Play script, sample observation,
    /// terminal prefills, static comparables). Forced on by `-DEALDemoShortcuts`.
    var demoShortcuts: Bool {
        didSet { defaults.set(demoShortcuts, forKey: Keys.demoShortcuts) }
    }
    /// Greeting on the mode picker.
    var displayName: String {
        didSet { defaults.set(displayName, forKey: Keys.displayName) }
    }

    /// `displayName`, or the default when blank.
    var greetingName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultDisplayName : trimmed
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Keys.backendURL) ?? ""
        // A saved localhost/blank value is useless on a device; prefer the build's default there.
        backendURLString = saved.isEmpty || (saved.contains("localhost") && !Config.defaultBackendURL.contains("localhost"))
            ? Config.defaultBackendURL : saved
        supabaseURLString = defaults.string(forKey: Keys.supabaseURL) ?? Config.defaultSupabaseURL
        supabaseAnonKey = defaults.string(forKey: Keys.supabaseAnonKey) ?? Config.defaultSupabaseAnonKey
        demoShortcuts = ProcessInfo.processInfo.arguments.contains(Self.demoShortcutsLaunchArgument)
            || defaults.bool(forKey: Keys.demoShortcuts)
        displayName = defaults.string(forKey: Keys.displayName) ?? Self.defaultDisplayName
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
        demoShortcuts = false
        displayName = Self.defaultDisplayName
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
