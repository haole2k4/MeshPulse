import Foundation

/// Fixed-capacity deduplication cache with O(1) lookup and O(1) ring-buffer eviction.
///
/// Each insertion receives a monotonically increasing `generation` stored alongside both
/// the ring slot and the dictionary entry so stale ring slots from expired/re-inserted UUIDs
/// can never evict a newer active entry upon wrap-around.
public struct BoundedSeenCache: Sendable {
    private struct Slot: Sendable {
        let id: UUID
        let generation: UInt64
    }

    private struct Entry: Sendable {
        let timestamp: Date
        let generation: UInt64
    }

    public let capacity: Int
    public let maxAge: TimeInterval

    private var ring: [Slot?]
    private var writeIndex: Int = 0
    private var nextGeneration: UInt64 = 1
    private var entries: [UUID: Entry] = [:]

    public init(capacity: Int = 2048, maxAge: TimeInterval = 600) {
        precondition(capacity > 0 && maxAge > 0, "BoundedSeenCache capacity and maxAge must be positive.")
        self.capacity = capacity
        self.maxAge = maxAge
        self.ring = Array(repeating: nil, count: capacity)
    }

    /// Inserts `id` if it is unseen or expired at `now`.
    /// - Returns: `true` if `id` was newly accepted; `false` if an unexpired entry already exists.
    @discardableResult
    public mutating func insertIfNew(_ id: UUID, now: Date = Date()) -> Bool {
        if let existing = entries[id], !isExpired(existing, now: now) {
            return false
        }

        let generation = nextGeneration
        nextGeneration &+= 1

        if let evictedSlot = ring[writeIndex],
           let currentEntry = entries[evictedSlot.id],
           currentEntry.generation == evictedSlot.generation
        {
            entries.removeValue(forKey: evictedSlot.id)
        }

        ring[writeIndex] = Slot(id: id, generation: generation)
        entries[id] = Entry(timestamp: now, generation: generation)
        writeIndex = (writeIndex + 1) % capacity
        return true
    }

    /// Checks whether `id` is currently held in the cache and has not expired at `now`.
    public func contains(_ id: UUID, now: Date = Date()) -> Bool {
        guard let entry = entries[id] else { return false }
        return !isExpired(entry, now: now)
    }

    /// Number of entries currently tracked in the ring dictionary (bounded by `capacity`).
    public var activeCount: Int {
        entries.count
    }

    /// Number of non-expired entries at a given reference timestamp `now`.
    public func activeCount(now: Date) -> Int {
        entries.values.reduce(into: 0) { count, entry in
            if !isExpired(entry, now: now) {
                count += 1
            }
        }
    }

    /// Clears all cached packet identifiers and resets the ring cursor.
    public mutating func reset() {
        ring = Array(repeating: nil, count: capacity)
        writeIndex = 0
        entries.removeAll(keepingCapacity: true)
    }

    private func isExpired(_ entry: Entry, now: Date) -> Bool {
        now.timeIntervalSince(entry.timestamp) >= maxAge
    }
}
