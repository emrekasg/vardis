/// Fixed-capacity ring buffer. Appending never allocates after init, which keeps live ticks allocation-free.
public struct RingBuffer<Element: Sendable>: Sendable {
    private var storage: [Element]
    private var head = 0
    public private(set) var count = 0
    public let capacity: Int

    public init(capacity: Int, filler: Element) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = Array(repeating: filler, count: capacity)
    }

    public mutating func append(_ element: Element) {
        storage[head] = element
        head = (head + 1) % capacity
        count = Swift.min(count + 1, capacity)
    }

    public var last: Element? {
        count == 0 ? nil : storage[(head - 1 + capacity) % capacity]
    }

    /// Oldest to newest.
    public var elements: [Element] {
        guard count > 0 else { return [] }
        let start = (head - count + capacity) % capacity
        return (0..<count).map { storage[(start + $0) % capacity] }
    }

    /// Calls `body` oldest to newest without building an array.
    public func forEach(_ body: (Int, Element) -> Void) {
        let start = (head - count + capacity) % capacity
        for i in 0..<count { body(i, storage[(start + i) % capacity]) }
    }
}
