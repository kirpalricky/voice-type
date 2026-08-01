import Foundation

/// Races `operation` against cooperative cancellation of the current task. `Transcriber`
/// and `Enhancer` don't check `Task.isCancelled` internally, so awaiting them directly
/// means a Cancel click has no visible effect until the call finishes on its own (most
/// noticeable during the multi-second Foundation Models polish step). Polling cancellation
/// on a sibling task lets us abandon the wait within ~100ms instead.
func cancellable<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw CancellationError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        return result
    }
}
