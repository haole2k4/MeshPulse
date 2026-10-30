import Foundation

/// Durable snapshot of a Node's `DTNOutbox` and TOFU-pinned peer identities.
public struct PersistedMeshState: Codable, Sendable, Equatable {
    public var outbox: DTNOutbox
    public var pinnedPeers: [NodeIdentity]

    public init(
        outbox: DTNOutbox = DTNOutbox(),
        pinnedPeers: [NodeIdentity] = []
    ) {
        self.outbox = outbox
        self.pinnedPeers = pinnedPeers
    }
}

/// Atomic JSON disk store for persisting `DTNOutbox` packets and TOFU public keys across app restarts.
public struct DiskDTNStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultStore(fileManager: FileManager = .default) -> DiskDTNStore {
        let baseDir =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let url = baseDir
            .appendingPathComponent("MeshPulse", isDirectory: true)
            .appendingPathComponent("live_mesh_state.json", isDirectory: false)
        return DiskDTNStore(fileURL: url)
    }

    /// Loads persisted DTN records and TOFU peer keys, pruning expired packets.
    /// Gracefully returns an empty `PersistedMeshState` if the file is missing or corrupted.
    public func load(now: Date = Date()) -> PersistedMeshState {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return PersistedMeshState()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard var decoded = try? decoder.decode(PersistedMeshState.self, from: data) else {
            return PersistedMeshState()
        }
        decoded.outbox.pruneExpired(now: now)
        return decoded
    }

    /// Atomically writes `state` to `fileURL`, creating parent directories if needed.
    public func save(_ state: PersistedMeshState) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }
}

extension MeshRouter {
    /// Restores persisted `DTNOutbox` packets (seeding `seenCache` to prevent self-echo loops)
    /// and TOFU-pinned peer identities after an app restart.
    public mutating func restorePersistedState(_ state: PersistedMeshState, now: Date = Date()) {
        var restoredOutbox = state.outbox
        restoredOutbox.pruneExpired(now: now)
        self.dtnOutbox = restoredOutbox

        for packetID in restoredOutbox.summaryVector(now: now) {
            _ = seenCache.insertIfNew(packetID, now: now)
        }
        for peer in state.pinnedPeers {
            registerPeerIdentity(peer)
        }
    }

    /// Captures the current `DTNOutbox` and known peer identities for atomic persistence.
    public func snapshotPersistedState(now: Date = Date()) -> PersistedMeshState {
        var prunedOutbox = dtnOutbox
        prunedOutbox.pruneExpired(now: now)
        let peers = knownPeers
            .map(\.identity)
            .sorted { $0.nodeID < $1.nodeID }
        return PersistedMeshState(outbox: prunedOutbox, pinnedPeers: peers)
    }
}
