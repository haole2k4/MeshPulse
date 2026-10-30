import Foundation

/// A single store-and-forward record held in a Node's `DTNOutbox`.
public struct StoredDTNRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { packet.id }
    public var packet: MeshPacket
    public var queuedAt: Date
    public var expiresAt: Date
    public var forwardedPeers: Set<String>

    public init(
        packet: MeshPacket,
        queuedAt: Date,
        expiresAt: Date,
        forwardedPeers: Set<String> = []
    ) {
        self.packet = packet
        self.queuedAt = queuedAt
        self.expiresAt = expiresAt
        self.forwardedPeers = forwardedPeers
    }
}

/// Bounded Delay-Tolerant Networking holding queue for undelivered Mesh Packets.
///
/// Supports Spray-and-Wait replica quota tracking (`remainingCopies`), per-peer duplicate push
/// suppression (`forwardedPeers`), and Epidemic Summary Vector reconciliation.
public struct DTNOutbox: Codable, Sendable, Equatable {
    public let capacity: Int
    private var records: [UUID: StoredDTNRecord]

    public init(capacity: Int = 256) {
        precondition(capacity > 0, "DTNOutbox capacity must be positive.")
        self.capacity = capacity
        self.records = [:]
    }

    public var count: Int {
        records.count
    }

    @discardableResult
    public mutating func enqueue(
        _ packet: MeshPacket,
        now: Date = Date(),
        lifetime: TimeInterval = 86_400,
        initialForwardedPeers: Set<String> = []
    ) -> StoredDTNRecord {
        pruneExpired(now: now)

        if var existing = records[packet.id] {
            existing.packet = packet
            existing.forwardedPeers.formUnion(initialForwardedPeers)
            records[packet.id] = existing
            return existing
        }

        if records.count >= capacity {
            evictOldest()
        }

        let record = StoredDTNRecord(
            packet: packet,
            queuedAt: now,
            expiresAt: now.addingTimeInterval(max(1, lifetime)),
            forwardedPeers: initialForwardedPeers
        )
        records[packet.id] = record
        return record
    }

    @discardableResult
    public mutating func markDelivered(packetID: UUID) -> Bool {
        records.removeValue(forKey: packetID) != nil
    }

    public mutating func pruneExpired(now: Date = Date()) {
        records = records.filter { _, record in
            now < record.expiresAt
        }
    }

    /// Chronologically ordered list of unexpired packet IDs held in the outbox.
    public func summaryVector(now: Date = Date()) -> [UUID] {
        records.values
            .filter { now < $0.expiresAt }
            .sorted { lhs, rhs in
                if lhs.queuedAt != rhs.queuedAt {
                    return lhs.queuedAt < rhs.queuedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map(\.id)
    }

    /// Retrieves unexpired `MeshPacket` values matching `ids` in the requested order.
    public func packets(for ids: [UUID], now: Date = Date()) -> [MeshPacket] {
        ids.compactMap { id in
            guard let record = records[id], now < record.expiresAt else {
                return nil
            }
            return record.packet
        }
    }

    /// Returns all unexpired records sorted newest-first for Tab 3 (`DTN Outbox`).
    public func allRecords(now: Date = Date()) -> [StoredDTNRecord] {
        records.values
            .filter { now < $0.expiresAt }
            .sorted { lhs, rhs in
                if lhs.queuedAt != rhs.queuedAt {
                    return lhs.queuedAt > rhs.queuedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    public func record(for packetID: UUID, now: Date = Date()) -> StoredDTNRecord? {
        guard let record = records[packetID], now < record.expiresAt else {
            return nil
        }
        return record
    }

    /// Updates `forwardedPeers` and optionally `remainingCopies` (for Binary Spray-and-Wait).
    public mutating func recordForwarded(
        packetID: UUID,
        toPeerID peerID: String,
        remainingCopies: Int? = nil
    ) {
        guard var record = records[packetID] else { return }
        record.forwardedPeers.insert(peerID)
        if let remainingCopies {
            record.packet.remainingCopies = max(1, remainingCopies)
        }
        records[packetID] = record
    }

    private mutating func evictOldest() {
        let oldestID = records.values.min { lhs, rhs in
            if lhs.queuedAt != rhs.queuedAt {
                return lhs.queuedAt < rhs.queuedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }?.id

        if let oldestID {
            records.removeValue(forKey: oldestID)
        }
    }
}
