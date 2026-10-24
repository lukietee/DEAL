import Foundation

enum APIError: LocalizedError, Sendable {
    case invalidURL(String)
    case transport(String)
    case server(status: Int, message: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let s): "Invalid backend URL: \(s)"
        case .transport(let s): "Can't reach the backend. \(s)"
        case .server(let status, let message): "Backend error \(status): \(message)"
        case .decoding(let s): "Unexpected response from backend. \(s)"
        }
    }
}

/// Thin async client for the backend API in Section 12.5. All writes go through here;
/// Supabase is only ever used for Realtime reads.
struct APIClient: Sendable {
    var baseURL: URL
    var session: URLSession = .shared

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    // MARK: Endpoints

    func health() async throws -> Bool {
        let (_, status) = try await raw("GET", "/health", body: Optional<Empty>.none)
        return (200..<300).contains(status)
    }

    func createSession(_ body: CreateSessionBody) async throws -> Session {
        try await send("POST", "/sessions", body: body, unwrap: "session")
    }

    func joinSession(code: String) async throws -> Session {
        try await send("POST", "/sessions/join", body: JoinSessionBody(joinCode: code), unwrap: "session")
    }

    func listSessions() async throws -> [Session] {
        try await send("GET", "/sessions", body: Optional<Empty>.none, unwrap: "sessions")
    }

    /// Settings "Delete all sessions".
    func deleteAllSessions() async throws {
        _ = try await raw("DELETE", "/sessions", body: Optional<Empty>.none, expectSuccess: true)
    }

    func sessionState(id: String) async throws -> SessionState {
        try await send("GET", "/sessions/\(id.urlPathEscaped)", body: Optional<Empty>.none)
    }

    func postEvent(sessionID: String, speaker: Speaker, text: String) async throws -> DealEvent {
        try await send("POST", "/sessions/\(sessionID.urlPathEscaped)/events",
                       body: PostEventBody(speaker: speaker, text: text), unwrap: "event")
    }

    func playScript(sessionID: String, scriptID: String, intervalMs: Int? = Config.scriptIntervalMs) async throws -> PlayScriptResponse {
        try await send("POST", "/sessions/\(sessionID.urlPathEscaped)/script/play",
                       body: PlayScriptBody(scriptId: scriptID, intervalMs: intervalMs))
    }

    /// Response ("updated terms") is not needed: the next sync tick picks up the change.
    func fixTerm(sessionID: String, termID: String, correction: TermCorrection) async throws {
        _ = try await raw("PATCH", "/sessions/\(sessionID.urlPathEscaped)/terms",
                          body: FixTermBody(termId: termID, correction: correction), expectSuccess: true)
    }

    func draftAgreement(sessionID: String) async throws -> Agreement {
        try await send("POST", "/sessions/\(sessionID.urlPathEscaped)/agreement",
                       body: Optional<Empty>.none, unwrap: "agreement")
    }

    func confirmAgreement(id: String, role: Speaker) async throws -> Agreement {
        try await send("POST", "/agreements/\(id.urlPathEscaped)/confirm", body: ConfirmBody(role: role), unwrap: "agreement")
    }

    func createPaymentRequest(sessionID: String, lineItems: [LineItem]) async throws -> PaymentRequest {
        try await send("POST", "/sessions/\(sessionID.urlPathEscaped)/payment-requests",
                       body: PaymentRequestBody(lineItems: lineItems), unwrap: "payment_request")
    }

    func decide(paymentRequestID: String, decision: PaymentDecision) async throws -> PaymentRequest {
        try await send("POST", "/payment-requests/\(paymentRequestID.urlPathEscaped)/decision",
                       body: DecisionBody(decision: decision), unwrap: "payment_request")
    }

    func pay(paymentRequestID: String) async throws -> Receipt {
        try await send("POST", "/payment-requests/\(paymentRequestID.urlPathEscaped)/pay",
                       body: Optional<Empty>.none, unwrap: "receipt")
    }

    func comparables(category: DealCategory) async throws -> [Comparable] {
        let (data, _) = try await raw("GET", "/comparables/\(category.rawValue)", body: Optional<Empty>.none, expectSuccess: true)
        return try Self.decodeComparables(data)
    }

    // MARK: Decoding

    /// Accepts a bare array, or an object with `listings` / `comparables` (content/comparables/*.json shape).
    static func decodeComparables(_ data: Data) throws -> [Comparable] {
        if let list = try? decoder.decode([Comparable].self, from: data) { return list }
        struct Wrapped: Decodable { var listings: [Comparable]?; var comparables: [Comparable]? }
        do {
            let w = try decoder.decode(Wrapped.self, from: data)
            return w.listings ?? w.comparables ?? []
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// Decodes `T`, or `{ "<unwrap>": T }` if the backend wraps its response.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, unwrap: String? = nil) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch let direct {
            if let unwrap, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let inner = obj[unwrap], JSONSerialization.isValidJSONObject(inner),
               let innerData = try? JSONSerialization.data(withJSONObject: inner),
               let value = try? decoder.decode(T.self, from: innerData) {
                return value
            }
            throw APIError.decoding(Self.describe(direct))
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let ctx):
            "Missing key '\(key.stringValue)' at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case DecodingError.typeMismatch(_, let ctx), DecodingError.valueNotFound(_, let ctx), DecodingError.dataCorrupted(let ctx):
            "\(ctx.debugDescription) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        default:
            error.localizedDescription
        }
    }

    // MARK: Transport

    private struct Empty: Encodable {}

    private func send<B: Encodable, T: Decodable>(_ method: String, _ path: String, body: B?, unwrap: String? = nil) async throws -> T {
        let (data, _) = try await raw(method, path, body: body, expectSuccess: true)
        return try Self.decode(T.self, from: data, unwrap: unwrap)
    }

    @discardableResult
    private func raw<B: Encodable>(_ method: String, _ path: String, body: B?, expectSuccess: Bool = false) async throws -> (Data, Int) {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw APIError.invalidURL(baseURL.absoluteString + path)
        }
        var request = URLRequest(url: url, timeoutInterval: Config.requestTimeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Skips ngrok's browser interstitial on free tunnels.
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        } else if method != "GET" {
            // Fastify rejects an empty body with a JSON content-type; send `{}`.
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if expectSuccess, !(200..<300).contains(status) {
            throw APIError.server(status: status, message: Self.errorMessage(from: data))
        }
        return (data, status)
    }

    /// Reads `{error}` / `{message}` / zod-style bodies; falls back to raw text.
    static func errorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "error", "detail"] {
                if let s = obj[key] as? String, !s.isEmpty { return s }
                if let inner = obj[key] as? [String: Any], let s = inner["message"] as? String { return s }
            }
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "No details" : String(text.prefix(200))
    }
}

extension String {
    var urlPathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? self
    }
}
