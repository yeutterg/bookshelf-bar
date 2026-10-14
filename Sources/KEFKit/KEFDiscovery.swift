import Foundation
import Network
import dnssd

/// A speaker advertised over Bonjour as `_kef-info._tcp`. The TXT record carries everything we
/// need to list it without an HTTP call.
public struct KEFSpeakerInfo: Sendable, Hashable, Identifiable, Codable {
    /// Stable identity across IP changes and renames.
    public var kefId: String
    public var name: String
    public var modelName: String
    public var model: String
    public var serialNumber: String
    /// The secondary (left) speaker of the pair.
    public var serialNumberSecondary: String
    public var firmware: String
    public var mac: String
    /// Bonjour instance name, used to resolve the current address.
    public var serviceName: String

    public var id: String { kefId }

    init?(serviceName: String, txt: [String: String]) {
        guard let kefId = txt["kefId"] else { return nil }
        self.kefId = kefId
        self.serviceName = serviceName
        name = txt["name"] ?? serviceName
        modelName = txt["modelName"] ?? "KEF"
        model = txt["model"] ?? ""
        serialNumber = txt["serialNumber"] ?? ""
        serialNumberSecondary = txt["serialNumberSlave"] ?? ""
        firmware = txt["version"] ?? ""
        mac = txt["mac"] ?? ""
    }
}

/// Browses for KEF speakers on the local network. Requires the Local Network permission
/// (`NSLocalNetworkUsageDescription` + `NSBonjourServices` in Info.plist).
public final class KEFDiscovery: @unchecked Sendable {
    public static let serviceType = "_kef-info._tcp"

    private let queue = DispatchQueue(label: "KEFDiscovery")
    private var browser: NWBrowser?

    public init() {}

    /// Current set of speakers, re-emitted whenever it changes.
    public func speakers() -> AsyncStream<[KEFSpeakerInfo]> {
        AsyncStream { continuation in
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { results, _ in
                let speakers = results.compactMap { result -> KEFSpeakerInfo? in
                    guard case .service(let name, _, _, _) = result.endpoint,
                          case .bonjour(let txt) = result.metadata else { return nil }
                    return KEFSpeakerInfo(serviceName: name, txt: txt.dictionary)
                }
                continuation.yield(speakers.sorted { $0.name < $1.name })
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { continuation.finish() }
            }
            browser.start(queue: queue)
            self.browser = browser
            continuation.onTermination = { _ in browser.cancel() }
        }
    }

    /// Resolves a speaker's Bonjour service to an IP address usable with `KEFClient`.
    public static func resolveHost(for speaker: KEFSpeakerInfo, timeout: Duration = .seconds(5)) async throws -> String {
        let endpoint = NWEndpoint.service(name: speaker.serviceName, type: serviceType, domain: "local.", interface: nil)
        // Prefer IPv4: a link-local IPv6 address needs an interface zone that URLs handle poorly.
        let params = NWParameters.tcp
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: params)
        defer { connection.cancel() }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                        let once = Once()
                        connection.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint {
                                    once.run { cont.resume(returning: Self.format(host)) }
                                } else {
                                    once.run { cont.resume(throwing: KEFError.unexpectedResponse("no address")) }
                                }
                            case .waiting(let error):
                                // macOS reports a missing Local Network permission as a waiting path.
                                if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                                    once.run { cont.resume(throwing: KEFError.localNetworkDenied) }
                                } else {
                                    once.run { cont.resume(throwing: error) }
                                }
                            case .failed(let error):
                                once.run { cont.resume(throwing: error) }
                            case .cancelled:
                                once.run { cont.resume(throwing: CancellationError()) }
                            default: break
                            }
                        }
                        connection.start(queue: DispatchQueue(label: "KEFResolve"))
                    }
                } onCancel: {
                    connection.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                // The denial doesn't always arrive as a state change; check the path directly.
                if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    throw KEFError.localNetworkDenied
                }
                throw KEFError.timedOut(speaker.name)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    public enum LocalNetworkAccess: Sendable { case granted, denied, undetermined }

    /// Checks (and on first use, requests) the Local Network permission by starting a Bonjour
    /// browse. The first call triggers the system prompt; a denial shows up as a DNS
    /// PolicyDenied error on the browser. `undetermined` means no answer yet (prompt still open).
    public static func requestLocalNetworkAccess(timeout: Duration = .seconds(3)) async -> LocalNetworkAccess {
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        defer { browser.cancel() }
        return await withTaskGroup(of: LocalNetworkAccess.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<LocalNetworkAccess, Never>) in
                    let once = Once()
                    browser.stateUpdateHandler = { state in
                        switch state {
                        case .ready: once.run { cont.resume(returning: .granted) }
                        case .waiting(let error), .failed(let error):
                            if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                                once.run { cont.resume(returning: .denied) }
                            }
                        case .cancelled: once.run { cont.resume(returning: .undetermined) }
                        default: break
                        }
                    }
                    browser.start(queue: DispatchQueue(label: "KEFPermission"))
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                browser.cancel()
                return .undetermined
            }
            let result = await group.next() ?? .undetermined
            group.cancelAll()
            browser.cancel()
            return result
        }
    }

    /// Definitive Local Network check against a known address: a direct TCP connection reports
    /// `.localNetworkDenied` on its own path (Bonjour browsing can succeed while connections are
    /// still prohibited, so browsing alone isn't proof).
    public static func probeLocalNetwork(host: String, timeout: Duration = .seconds(2)) async -> LocalNetworkAccess {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 80, using: .tcp)
        defer { connection.cancel() }
        return await withTaskGroup(of: LocalNetworkAccess.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<LocalNetworkAccess, Never>) in
                    let once = Once()
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: once.run { cont.resume(returning: .granted) }
                        case .waiting, .failed:
                            let denied = connection.currentPath?.unsatisfiedReason == .localNetworkDenied
                            once.run { cont.resume(returning: denied ? .denied : .undetermined) }
                        case .cancelled: once.run { cont.resume(returning: .undetermined) }
                        default: break
                        }
                    }
                    connection.start(queue: DispatchQueue(label: "KEFProbe"))
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                connection.cancel()
                return .undetermined
            }
            let result = await group.next() ?? .undetermined
            group.cancelAll()
            return result
        }
    }

    static func format(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let a): return "\(a)".components(separatedBy: "%").first ?? "\(a)"
        case .ipv6(let a): return "[\("\(a)".components(separatedBy: "%").first ?? "\(a)")]"
        case .name(let n, _): return n
        @unknown default: return "\(host)"
        }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
