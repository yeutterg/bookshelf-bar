import Foundation

public enum KEFError: Error, LocalizedError, Equatable {
    case http(status: Int, body: String)
    case speaker(name: String, message: String)
    case unexpectedResponse(String)
    case unauthorized

    public var errorDescription: String? {
        switch self {
        case .http(let s, let b): "Speaker returned HTTP \(s): \(b.prefix(200))"
        case .speaker(let n, let m): "\(n): \(m)"
        case .unexpectedResponse(let s): "Unexpected response: \(s.prefix(200))"
        case .unauthorized: "The speaker rejected the request signature. Check the speaker password."
        }
    }
}

/// One update from the event queue.
public struct KEFEvent: Sendable, Hashable {
    public let path: KEFPath
    public let value: KEFValue?
}

/// A row from `getRows`.
public struct KEFRow: Sendable, Hashable {
    public let path: KEFPath?
    public let value: KEFValue?
}

/// Client for the speaker's local HTTP API (port 80). Stateless apart from the cached auth mode.
public final class KEFClient: Sendable {
    public let host: String
    let password: String
    let session: URLSession
    let signing: Signing

    public enum Signing: Sendable {
        /// Sign writes only when the speaker reports `authMode != none` (checked once, cached).
        case automatic
        case always
        case never
    }

    private let authModeCache = Cache<String>()

    public init(host: String, password: String = "", signing: Signing = .automatic) {
        self.host = host
        self.password = password
        self.signing = signing
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config)
    }

    var base: URL { URL(string: "http://\(host)")! }

    // MARK: Primitives

    public func get(_ path: KEFPath) async throws -> KEFValue {
        let data = try await send(getDataRequest(path))
        guard let first = try decodeArray(data).first else {
            throw KEFError.unexpectedResponse(String(decoding: data, as: UTF8.self))
        }
        return first
    }

    public func rows(_ path: KEFPath, from: Int = 0, to: Int = 300) async throws -> [KEFRow] {
        var c = URLComponents(url: base.appending(path: "api/getRows"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "path", value: path.rawValue), .init(name: "roles", value: "@all"),
                        .init(name: "from", value: "\(from)"), .init(name: "to", value: "\(to)")]
        let data = try await send(URLRequest(url: c.url!))
        let obj = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .array(let rows)? = obj["rows"] else { return [] }
        return rows.map { row in
            let value: KEFValue? = if case .object(let v)? = row["value"], let t = v["type"]?.string {
                KEFValue(type: t, payload: v[t] ?? .null)
            } else { nil }
            return KEFRow(path: row["path"]?.string.map { KEFPath($0) }, value: value)
        }
    }

    public func set(_ path: KEFPath, _ value: KEFValue) async throws {
        let url = base.appending(path: "api/setData")
        let request: URLRequest
        if try await shouldSign() {
            request = try KEFSigner.signedWrite(url: url, path: path, value: value, password: password)
        } else {
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try KEFSigner.encoder.encode(UnsignedBody(path: path.rawValue, role: "value", value: value))
            request = r
        }
        _ = try await send(request)
    }

    // MARK: Events

    /// Creates an event queue for `paths` and returns its id.
    public func subscribe(_ paths: [KEFPath]) async throws -> String {
        var r = URLRequest(url: base.appending(path: "api/event/modifyQueue"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = .object([
            "subscribe": .array(paths.map { .object(["path": .string($0.rawValue), "type": .string("itemWithValue")]) }),
            "unsubscribe": .array([]),
        ])
        r.httpBody = try JSONEncoder().encode(body)
        let data = try await send(r)
        guard let id = try? JSONDecoder().decode(String.self, from: data) else {
            throw KEFError.unexpectedResponse(String(decoding: data, as: UTF8.self))
        }
        return id
    }

    /// Long-polls the queue. Returns an empty array if nothing changed within `timeout`.
    public func poll(queue: String, timeout: Int = 20) async throws -> [KEFEvent] {
        var c = URLComponents(url: base.appending(path: "api/event/pollQueue"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "queueId", value: queue), .init(name: "timeout", value: "\(timeout)")]
        var r = URLRequest(url: c.url!)
        r.timeoutInterval = TimeInterval(timeout + 5)
        let data = try await send(r)
        guard case .array(let items) = try JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        return items.compactMap { item in
            guard let path = item["path"]?.string else { return nil }
            let value: KEFValue? = if case .object(let v)? = item["itemValue"], let t = v["type"]?.string {
                KEFValue(type: t, payload: v[t] ?? .null)
            } else { nil }
            return KEFEvent(path: KEFPath(path), value: value)
        }
    }

    // MARK: Transport

    func getDataRequest(_ path: KEFPath) -> URLRequest {
        var c = URLComponents(url: base.appending(path: "api/getData"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "path", value: path.rawValue), .init(name: "roles", value: "value")]
        return URLRequest(url: c.url!)
    }

    func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw KEFError.unauthorized }
        // The speaker reports most failures as JSON {"error": {...}}, sometimes with HTTP 200.
        if let err = try? JSONDecoder().decode(JSONValue.self, from: data)["error"] {
            throw KEFError.speaker(name: err["name"]?.string ?? "error", message: err["message"]?.string ?? "")
        }
        guard (200..<300).contains(status) else {
            throw KEFError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    func decodeArray(_ data: Data) throws -> [KEFValue] {
        try JSONDecoder().decode([KEFValue].self, from: data)
    }

    func shouldSign() async throws -> Bool {
        switch signing {
        case .always: return true
        case .never: return false
        case .automatic:
            if let mode = authModeCache.value { return mode != "none" }
            let mode = (try? await get(.authMode).string) ?? "none"
            authModeCache.value = mode
            return mode != "none"
        }
    }

    private struct UnsignedBody: Encodable {
        let path: String
        let role: String
        let value: KEFValue
    }
}

/// Tiny lock-protected box so the client can stay `Sendable`.
final class Cache<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
