import Foundation

public extension KEFClient {
    /// Live updates for `paths`. Re-creates the queue after errors (speaker reboot, network
    /// change, queue expiry) with backoff. Holds one idle long-poll connection; cancel the
    /// consuming task to stop it.
    func events(_ paths: [KEFPath], pollTimeout: Int = 20) -> AsyncStream<KEFEvent> {
        AsyncStream { continuation in
            let task = Task {
                var backoff: UInt64 = 1
                while !Task.isCancelled {
                    do {
                        let queue = try await subscribe(paths)
                        backoff = 1
                        while !Task.isCancelled {
                            for event in try await poll(queue: queue, timeout: pollTimeout) {
                                continuation.yield(event)
                            }
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        try? await Task.sleep(for: .seconds(backoff))
                        backoff = min(backoff * 2, 30)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
