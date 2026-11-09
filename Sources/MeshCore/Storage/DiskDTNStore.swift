import Foundation

/// Persisted peer directory record (`KnownPeerRecord`) storing identity, TOFU/QR trust state, and last seen telemetry.
public struct KnownPeerRecord: Codable, Sendable, Equatable, Identifiable {
    public var identity: NodeIdentity
    public var trustState: PeerTrustState
    public var conflictPublicKeyBase64: String?
    public var lastSeen: Date
    public var lastCoordinate: GeoCoordinate?

    public var id: String { identity.nodeID }

    public init(
        identity: NodeIdentity,
        trustState: PeerTrustState = .unverifiedTOFU,
        conflictPublicKeyBase64: String? = nil,
        lastSeen: Date = .distantPast,
        lastCoordinate: GeoCoordinate? = nil
    ) {
        self.identity = identity
        self.trustState = trustState
        self.conflictPublicKeyBase64 = conflictPublicKeyBase64
        self.lastSeen = lastSeen
        self.lastCoordinate = lastCoordinate
    }
}

/// Persisted chat message record (`PersistedMessage`) for Broadcast and 1-to-1 conversations.
public struct PersistedMessageRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let peerThreadID: String
    public let senderID: String
    public let senderName: String
    public let targetID: String
    public let text: String
    public let coordinate: GeoCoordinate?
    public var deliveryState: DeliveryState
    public var routeNames: [String]
    public var hopCount: Int
    public var remainingTTL: Int
    public var rttMs: Int?
    public let isEncrypted: Bool
    public let isOutgoing: Bool
    public let isSOS: Bool
    public let timestamp: Date
    public var voiceNote: VoiceNotePayload?
    public var imageJPEGData: Data?

    public init(
        id: UUID,
        peerThreadID: String,
        senderID: String,
        senderName: String,
        targetID: String,
        text: String,
        coordinate: GeoCoordinate? = nil,
        deliveryState: DeliveryState,
        routeNames: [String],
        hopCount: Int,
        remainingTTL: Int,
        rttMs: Int? = nil,
        isEncrypted: Bool,
        isOutgoing: Bool,
        isSOS: Bool,
        timestamp: Date,
        voiceNote: VoiceNotePayload? = nil,
        imageJPEGData: Data? = nil
    ) {
        self.id = id
        self.peerThreadID = peerThreadID
        self.senderID = senderID
        self.senderName = senderName
        self.targetID = targetID
        self.text = text
        self.coordinate = coordinate
        self.deliveryState = deliveryState
        self.routeNames = routeNames
        self.hopCount = hopCount
        self.remainingTTL = remainingTTL
        self.rttMs = rttMs
        self.isEncrypted = isEncrypted
        self.isOutgoing = isOutgoing
        self.isSOS = isSOS
        self.timestamp = timestamp
        self.voiceNote = voiceNote
        self.imageJPEGData = imageJPEGData
    }
}

/// Durable snapshot of a Node's `DTNOutbox`, `KnownPeerRecord` directory, and `PersistedMessageRecord` history.
public struct PersistedMeshState: Codable, Sendable, Equatable {
    public var outbox: DTNOutbox
    public var pinnedPeers: [NodeIdentity]
    public var knownPeerRecords: [KnownPeerRecord]
    public var messages: [PersistedMessageRecord]
    public var activeRollCall: SafetyRollCallState?
    public var activePoll: MeshPollState?

    public init(
        outbox: DTNOutbox = DTNOutbox(),
        pinnedPeers: [NodeIdentity] = [],
        knownPeerRecords: [KnownPeerRecord] = [],
        messages: [PersistedMessageRecord] = [],
        activeRollCall: SafetyRollCallState? = nil,
        activePoll: MeshPollState? = nil
    ) {
        self.outbox = outbox
        self.pinnedPeers = pinnedPeers
        self.knownPeerRecords = knownPeerRecords
        self.messages = messages
        self.activeRollCall = activeRollCall
        self.activePoll = activePoll
    }

    private enum CodingKeys: String, CodingKey {
        case outbox
        case pinnedPeers
        case knownPeerRecords
        case messages
        case activeRollCall
        case activePoll
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.outbox = try container.decodeIfPresent(DTNOutbox.self, forKey: .outbox) ?? DTNOutbox()
        self.pinnedPeers = try container.decodeIfPresent([NodeIdentity].self, forKey: .pinnedPeers) ?? []
        self.knownPeerRecords = try container.decodeIfPresent([KnownPeerRecord].self, forKey: .knownPeerRecords) ?? []
        self.messages = try container.decodeIfPresent([PersistedMessageRecord].self, forKey: .messages) ?? []
        self.activeRollCall = try container.decodeIfPresent(SafetyRollCallState.self, forKey: .activeRollCall)
        self.activePoll = try container.decodeIfPresent(MeshPollState.self, forKey: .activePoll)
    }
}

/// Atomic JSON disk store for persisting `DTNOutbox`, `KnownPeerRecord` (TOFU/QR keys), and `PersistedMessageRecord` history across app restarts.
public struct DiskDTNStore: Sendable {
    public static let maxPersistedMessages = 400
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

    /// Loads persisted DTN records, TOFU peer keys, and message history, pruning expired packets (>24h).
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
        if decoded.messages.count > Self.maxPersistedMessages {
            decoded.messages = Array(decoded.messages.suffix(Self.maxPersistedMessages))
        }
        return decoded
    }

    /// Atomically writes `state` to `fileURL`, creating parent directories if needed.
    public func save(_ state: PersistedMeshState) throws {
        var sanitized = state
        if sanitized.messages.count > Self.maxPersistedMessages {
            sanitized.messages = Array(sanitized.messages.suffix(Self.maxPersistedMessages))
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(sanitized)
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
        for record in state.knownPeerRecords {
            restorePeerRecord(record)
        }
        if let rc = state.activeRollCall {
            self.activeRollCall = rc
        }
        if let poll = state.activePoll {
            self.activePoll = poll
        }
    }

    /// Captures the current `DTNOutbox`, known peer identities, and optional message history for atomic persistence.
    public func snapshotPersistedState(
        now: Date = Date(),
        messages: [PersistedMessageRecord] = []
    ) -> PersistedMeshState {
        var prunedOutbox = dtnOutbox
        prunedOutbox.pruneExpired(now: now)
        let summaries = knownPeers
        let peers = summaries
            .map(\.identity)
            .sorted { $0.nodeID < $1.nodeID }
        let peerRecords = summaries
            .map { summary in
                KnownPeerRecord(
                    identity: summary.identity,
                    trustState: summary.trustState,
                    conflictPublicKeyBase64: summary.conflictPublicKeyBase64,
                    lastSeen: summary.lastSeen,
                    lastCoordinate: summary.lastCoordinate
                )
            }
            .sorted { $0.identity.nodeID < $1.identity.nodeID }
        return PersistedMeshState(
            outbox: prunedOutbox,
            pinnedPeers: peers,
            knownPeerRecords: peerRecords,
            messages: messages,
            activeRollCall: activeRollCall,
            activePoll: activePoll
        )
    }
}
