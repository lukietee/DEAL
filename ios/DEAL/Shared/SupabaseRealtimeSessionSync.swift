#if canImport(Supabase)
import Foundation
import Supabase

/// Realtime reads only (Section 12.4 security note). Subscribes to Postgres changes on
/// `events`, `agreements`, `payment_requests`, `receipts` filtered by `session_id`, and on
/// any change refetches the canonical state from the backend (`GET /sessions/:id`). This keeps
/// a single decode path and avoids depending on raw row shapes. A slow safety poll also runs
/// in case the socket drops.
@MainActor
final class SupabaseRealtimeSessionSync: SessionSync {
    private static let tables = ["events", "agreements", "payment_requests", "receipts", "sessions"]

    private let api: APIClient
    private let client: SupabaseClient
    private var channel: RealtimeChannelV2?
    private var listenTasks: [Task<Void, Never>] = []
    private var safetyPoll: Task<Void, Never>?
    private var sessionID: String?
    private var onState: (@MainActor (SessionState) -> Void)?
    private var onError: (@MainActor (Error) -> Void)?
    private var inFlight = false
    private var pendingRefetch = false

    var modeDescription: String { "Supabase Realtime" }

    init(api: APIClient, supabaseURL: URL, anonKey: String) {
        self.api = api
        self.client = SupabaseClient(supabaseURL: supabaseURL, supabaseKey: anonKey)
    }

    func start(sessionID: String, onState: @escaping @MainActor (SessionState) -> Void,
               onError: @escaping @MainActor (Error) -> Void) {
        stop()
        self.sessionID = sessionID
        self.onState = onState
        self.onError = onError

        let channel = client.channel("deal-session-\(sessionID)")
        self.channel = channel
        for table in Self.tables {
            let column = table == "sessions" ? "id" : "session_id"
            let stream = channel.postgresChange(AnyAction.self, schema: "public", table: table,
                                                filter: .eq(column, value: sessionID))
            listenTasks.append(Task { [weak self] in
                for await _ in stream {
                    await self?.fetch()
                }
            })
        }
        Task { [weak self] in
            do {
                try await channel.subscribeWithError()
            } catch {
                // Safety poll below keeps the session fresh even if Realtime can't connect.
                self?.onError?(error)
            }
            await self?.fetch()
        }

        let nanos = UInt64(Config.realtimeSafetyPollInterval * 1_000_000_000)
        safetyPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                await self?.fetch()
            }
        }
    }

    func refreshNow() {
        Task { await fetch() }
    }

    func stop() {
        listenTasks.forEach { $0.cancel() }
        listenTasks = []
        safetyPoll?.cancel()
        safetyPoll = nil
        if let channel {
            Task { await channel.unsubscribe() }
        }
        channel = nil
    }

    private func fetch() async {
        guard let sessionID else { return }
        if inFlight { pendingRefetch = true; return }
        inFlight = true
        defer { inFlight = false }
        repeat {
            pendingRefetch = false
            do {
                let state = try await api.sessionState(id: sessionID)
                onState?(state)
            } catch {
                onError?(error)
            }
        } while pendingRefetch
    }
}
#endif
