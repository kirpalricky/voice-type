import Foundation
import Testing
@testable import Yapboard

@Suite
struct CancellableTests {
    // MARK: - Happy Path Tests

    @Test
    func cancellable_FastOperation_ReturnsResult() async throws {
        let expectedValue = 42
        let result = try await cancellable {
            return expectedValue
        }
        #expect(result == expectedValue)
    }

    @Test
    func cancellable_FastOperation_WithString_ReturnsCorrectly() async throws {
        let expectedString = "hello world"
        let result = try await cancellable {
            return expectedString
        }
        #expect(result == expectedString)
    }

    // MARK: - Cancellation Tests

    @Test
    func cancellable_SlowOperation_CancelledByTask_ThrowsError() async throws {
        let startTime = Date()
        let task = Task {
            try await cancellable {
                // Sleep for 5 seconds
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "should not reach here"
            }
        }

        // Let the task start, then cancel after 100ms
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        // Await the result and capture elapsed time
        do {
            _ = try await task.value
            #expect(Bool(false), "Expected task to throw CancellationError")
        } catch is CancellationError {
            let elapsedTime = Date().timeIntervalSince(startTime)
            // Should complete much faster than 5 seconds (cancellation poll is ~100ms)
            #expect(elapsedTime < 1.0, "Cancellation should complete in < 1 second, took \(elapsedTime)s")
        }
    }

    @Test
    func cancellable_SlowOperation_ImmediateCancel_ThrowsQuickly() async throws {
        let startTime = Date()
        let task = Task {
            try await cancellable {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                return "slow result"
            }
        }

        // Cancel immediately
        task.cancel()

        do {
            _ = try await task.value
            #expect(Bool(false), "Expected task to throw CancellationError")
        } catch is CancellationError {
            let elapsedTime = Date().timeIntervalSince(startTime)
            #expect(elapsedTime < 1.0, "Cancellation should complete in < 1 second, took \(elapsedTime)s")
        }
    }

    @Test
    func cancellable_FastOperation_NoCancel_CompletesSuccessfully() async throws {
        let task = Task {
            try await cancellable {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                return "fast result"
            }
        }

        // Don't cancel - let it complete naturally
        let result = try await task.value
        #expect(result == "fast result")
    }

    // MARK: - Error Propagation Tests

    @Test
    func cancellable_OperationThrowsCustomError_ErrorPropagates() async throws {
        enum CustomError: Error, Equatable {
            case testError
        }

        let task = Task {
            try await cancellable {
                throw CustomError.testError
            }
        }

        do {
            _ = try await task.value
            #expect(Bool(false), "Expected task to throw CustomError")
        } catch let error as CustomError {
            #expect(error == .testError)
        } catch is CancellationError {
            #expect(Bool(false), "Expected CustomError, not CancellationError")
        }
    }

    @Test
    func cancellable_OperationThrowsError_BeforeCancellation_ErrorPropagates() async throws {
        enum CustomError: Error, Equatable {
            case immediateError
        }

        let task = Task {
            try await cancellable {
                // Throw immediately before any cancellation could happen
                throw CustomError.immediateError
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000) // Let it fail
        task.cancel()

        do {
            _ = try await task.value
            #expect(Bool(false), "Expected task to throw CustomError")
        } catch let error as CustomError {
            #expect(error == .immediateError)
        } catch is CancellationError {
            #expect(Bool(false), "Expected CustomError, not CancellationError")
        }
    }

    // MARK: - Complex Type Tests

    @Test
    func cancellable_ReturnsArray_CompletesSuccessfully() async throws {
        let expectedArray = [1, 2, 3, 4, 5]
        let result = try await cancellable {
            return expectedArray
        }
        #expect(result == expectedArray)
    }

    @Test
    func cancellable_ReturnsDictionary_CompletesSuccessfully() async throws {
        let expectedDict: [String: Int] = ["a": 1, "b": 2]
        let result = try await cancellable {
            return expectedDict
        }
        #expect(result == expectedDict)
    }

    struct TestData: Sendable, Equatable {
        let id: Int
        let name: String
    }

    @Test
    func cancellable_ReturnsCustomSendableType_CompletesSuccessfully() async throws {
        let expectedData = TestData(id: 123, name: "test")
        let result = try await cancellable {
            return expectedData
        }
        #expect(result == expectedData)
    }

    // MARK: - Multiple Cancellation Attempts

    @Test
    func cancellable_MultipleCancelCalls_HandledGracefully() async throws {
        let task = Task {
            try await cancellable {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return "result"
            }
        }

        // Cancel multiple times
        task.cancel()
        task.cancel()
        task.cancel()

        do {
            _ = try await task.value
            #expect(Bool(false), "Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }
    }

    // MARK: - Nested Operations

    @Test
    func cancellable_NestedCancellableOperations_CancelledAtOuterLevel() async throws {
        let task = Task {
            try await cancellable {
                return try await cancellable {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    return "nested result"
                }
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            #expect(Bool(false), "Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }
    }
}
