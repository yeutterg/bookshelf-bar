import Foundation

/// Runs `operation` with a hard deadline. Unlike a task-group timeout, this doesn't wait for the
/// operation to acknowledge cancellation: when macOS blocks local networking, some network calls
/// ignore cancellation, and a structured timeout then hangs as long as they do.
public func withDeadline<T: Sendable>(_ seconds: Double, label: String = "operation",
                                      _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let box = ResumeOnce<T>()
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        box.set(cont)
        let work = Task {
            do { box.resume(.success(try await operation())) } catch { box.resume(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            work.cancel()
            box.resume(.failure(KEFError.timedOut(label)))
        }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    private var done = false

    func set(_ c: CheckedContinuation<T, Error>) { lock.withLock { cont = c } }

    func resume(_ result: Result<T, Error>) {
        let c: CheckedContinuation<T, Error>? = lock.withLock {
            guard !done else { return nil }
            done = true
            defer { cont = nil }
            return cont
        }
        c?.resume(with: result)
    }
}
