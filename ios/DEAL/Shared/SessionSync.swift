import Foundation

/// Keeps a session's full state (`GET /sessions/:id`) fresh on this phone.
/// Implementations: `PollingSessionSync` (default; works with the in-memory mock backend)
/// and `SupabaseRealtimeSessionSync` (Realtime change notifications trigger a refetch).
@MainActor
protocol SessionSync: AnyObject {
    var modeDescription: String { get }
    func start(sessionID: String, onState: @escaping @MainActor (SessionState) -> Void,
               onError: @escaping @MainActor (Error) -> Void)
    /// Force an immediate refetch (e.g. right after this phone performed a write).
    func refreshNow()
    func stop()
}

/// Polls `GET /sessions/:id` every `interval` seconds.
@MainActor
final class PollingSessionSync: SessionSync {
    private let api: APIClient
    private let interval: TimeInterval
    private var task: Task<Void, Never>?
    private var sessionID: String?
    private var onState: (@MainActor (SessionState) -> Void)?
    private var onError: (@MainActor (Error) -> Void)?
    private var inFlight = false

    var modeDescription: String { "Polling every \(interval.formatted())s" }

    init(api: APIClient, interval: TimeInterval = Config.pollInterval) {
        self.api = api
        self.interval = interval
    }

    func start(sessionID: String, onState: @escaping @MainActor (SessionState) -> Void,
               onError: @escaping @MainActor (Error) -> Void) {
        stop()
        self.sessionID = sessionID
        self.onState = onState
        self.onError = onError
        let nanos = UInt64(interval * 1_000_000_000)
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetch()
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    func refreshNow() {
        Task { await fetch() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func fetch() async {
        guard let sessionID, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        do {
            let state = try await api.sessionState(id: sessionID)
            onState?(state)
        } catch is CancellationError {
        } catch {
            onError?(error)
        }
    }
}

enum SessionSyncFactory {
    /// Supabase Realtime when configured (and the SDK is linked), else polling.
    @MainActor
    static func make(api: APIClient, supabase: (url: URL, anonKey: String)?) -> SessionSync {
        #if canImport(Supabase)
        if let supabase {
            return SupabaseRealtimeSessionSync(api: api, supabaseURL: supabase.url, anonKey: supabase.anonKey)
        }
        #endif
        return PollingSessionSync(api: api)
    }
}
