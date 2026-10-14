import Foundation

/// Finds the address of a known speaker as reliably as possible.
///
/// Measured: in deep standby the speaker stays visible in Bonjour browse results but stops
/// answering address resolution, while plain HTTP to its IP still works. So the last known IP
/// is tried first, and Bonjour runs in parallel to cover IP changes. Every candidate is verified
/// by reading the speaker's `kefId`, so a reassigned IP can't connect us to the wrong device.
public enum KEFLocator {
    public static func locate(kefId: String, cachedHost: String?, bonjour: KEFSpeakerInfo?,
                              timeout: Duration = .seconds(8)) async throws -> String {
        try await withThrowingTaskGroup(of: String?.self) { group in
            var candidates = 0
            if let cachedHost {
                candidates += 1
                group.addTask { try await verify(cachedHost, kefId: kefId) }
            }
            if let bonjour {
                candidates += 1
                group.addTask {
                    // Give the cached IP a head start; it's the common case and cheaper.
                    if cachedHost != nil { try await Task.sleep(for: .milliseconds(300)) }
                    let host = try await KEFDiscovery.resolveHost(for: bonjour, timeout: .seconds(5))
                    return try await verify(host, kefId: kefId)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            guard candidates > 0 else { throw KEFError.timedOut("speaker") }

            var lastError: Error = KEFError.timedOut("speaker")
            var finished = 0
            while finished < candidates {
                do {
                    guard let result = try await group.next() else { break }
                    guard let host = result else { break } // overall timeout
                    group.cancelAll()
                    return host
                } catch {
                    lastError = error
                    finished += 1
                }
            }
            group.cancelAll()
            throw lastError
        }
    }

    /// Confirms `host` is the speaker with `kefId` (short timeout).
    public static func verify(_ host: String, kefId: String) async throws -> String {
        let client = KEFClient(host: host, timeout: 3)
        let id = try await client.get("settings:/kef/host/kefId").string
        guard id == kefId else { throw KEFError.wrongSpeaker }
        return host
    }
}
