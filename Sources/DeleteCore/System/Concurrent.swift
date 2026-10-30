import Foundation

/// Starts `work` on a thread of its own immediately; `value` blocks until it has finished.
///
/// Not a GCD queue: work here often waits on more `Concurrent` work (a plan on its lookups), and
/// waiting pool threads starved GCD's small pool (nine companion plans at once took 63 s).
final class Concurrent<Value: Sendable>: @unchecked Sendable {
    private let group = DispatchGroup()
    private var result: Value?

    init(_ work: @escaping @Sendable () -> Value) {
        group.enter()
        let thread = Thread {
            self.result = work()
            self.group.leave()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    var value: Value {
        group.wait()
        guard let result else { preconditionFailure("Concurrent work finished without a result.") }
        return result
    }

    /// Waits for `work` without using its result.
    func wait() { group.wait() }
}

/// Fixed slots filled from `DispatchQueue.concurrentPerform`, each index written by exactly one
/// iteration and read only after it returns.
final class UnsafeResults<Value>: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Value?>

    init(count: Int) {
        storage = .allocate(capacity: count)
        storage.initialize(repeating: nil)
    }

    deinit {
        storage.deinitialize()
        storage.deallocate()
    }

    subscript(index: Int) -> Value? {
        get { storage[index] }
        set { storage[index] = newValue }
    }

    var values: [Value] {
        storage.map { value in
            guard let value else { preconditionFailure("Concurrent result slot was not filled.") }
            return value
        }
    }
}
