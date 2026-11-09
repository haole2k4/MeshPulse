import Foundation

// MARK: - Identity & Routing Configuration

public struct NodeIdentity: Codable, Sendable, Hashable, Identifiable {
    public let nodeID: String
    public var displayName: String
    public var publicKeyBase64: String?

    public var id: String { nodeID }

    public init(
        nodeID: String,
        displayName: String,
        publicKeyBase64: String? = nil
    ) {
        self.nodeID = nodeID
        self.displayName = displayName
        self.publicKeyBase64 = publicKeyBase64
    }

    /// Deterministic 64-bit SHA-256 fingerprint formatted as `"XXXX-XXXX-XXXX-XXXX"`
    /// over the decoded Base64 public key bytes. Identical on Linux and iOS.
    public var publicKeyFingerprint: String? {
        guard let base64 = publicKeyBase64,
              !base64.isEmpty,
              let keyData = Data(base64Encoded: base64),
              !keyData.isEmpty
        else {
            return nil
        }
        return CoreSHA256.fingerprint64HexGrouped(keyData)
    }

    /// Out-of-band QR verification URI (`meshpulse://verify?node=<id>&fp=<fingerprint>&key=<base64>`).
    public var verificationURIString: String {
        var components = URLComponents()
        components.scheme = "meshpulse"
        components.host = "verify"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "node", value: nodeID),
            URLQueryItem(name: "fp", value: publicKeyFingerprint ?? ""),
        ]
        if let publicKeyBase64, !publicKeyBase64.isEmpty {
            items.append(URLQueryItem(name: "key", value: publicKeyBase64))
        }
        components.queryItems = items
        return components.string ?? "meshpulse://verify?node=\(nodeID)&fp=\(publicKeyFingerprint ?? "")"
    }

    /// Parses a `meshpulse://verify?node=<id>&fp=<fingerprint>[&key=<base64>]` QR string.
    public static func parseVerificationURI(
        _ rawString: String
    ) -> (nodeID: String, fingerprint: String, publicKeyBase64: String?)? {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "meshpulse",
              components.host?.lowercased() == "verify",
              let items = components.queryItems
        else {
            return nil
        }
        guard let nodeID = items.first(where: { $0.name == "node" })?.value,
              !nodeID.isEmpty,
              let fp = items.first(where: { $0.name == "fp" })?.value,
              !fp.isEmpty
        else {
            return nil
        }
        let key = items.first(where: { $0.name == "key" })?.value
        if let key, !key.isEmpty {
            let candidate = NodeIdentity(nodeID: nodeID, displayName: nodeID, publicKeyBase64: key)
            if let computedFP = candidate.publicKeyFingerprint,
               computedFP.uppercased() != fp.uppercased()
            {
                return nil
            }
        }
        return (nodeID, fp.uppercased(), (key?.isEmpty == false) ? key : nil)
    }
}

public enum PeerTrustState: String, Codable, Sendable, Equatable {
    /// 🔒 E2EE Tự động (Ghim khóa lần đầu qua sóng vô tuyến TOFU)
    case unverifiedTOFU
    /// 🛡️ Đã xác thực tận tay (Đã đối chiếu vân tay hoặc quét mã QR ngoài băng tần)
    case verifiedOutOfBand
    /// ⚠️ Cảnh báo bảo mật: Cùng PeerID nhưng khóa công khai bị thay đổi (Nghi vấn MITM)
    case keyConflict
}

public enum PacketType: String, Codable, Sendable, CaseIterable {
    case chat
    case ack
    case ping
    case pong
    case heartbeat
    case summaryVector
    case packetRequest
    case sos
    case mediaChunk
    case voiceNote
    case rollCall
    case poll
}

public enum RoutingStrategy: String, Codable, Sendable, CaseIterable, Identifiable {
    case managedFlooding
    case sprayAndWait
    case epidemic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .managedFlooding:
            "Managed Flooding"
        case .sprayAndWait:
            "Binary Spray-and-Wait"
        case .epidemic:
            "Epidemic Routing"
        }
    }

    public var subtitle: String {
        switch self {
        case .managedFlooding:
            "Định tuyến tối ưu 1–2 bước nhảy kèm phát tán chống lặp có kiểm soát."
        case .sprayAndWait:
            "Chia đôi hạn ngạch bản sao (L/2) cho nút trung gian để giảm tải mạng."
        case .epidemic:
            "Đối chiếu Summary Vector để đồng bộ bù các gói tin DTN còn thiếu."
        }
    }
}

// MARK: - Payloads

public struct GeoCoordinate: Codable, Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let accuracyMeters: Double
    public let altitudeMeters: Double?
    public let speedMetersPerSecond: Double?

    public init(
        latitude: Double,
        longitude: Double,
        accuracyMeters: Double,
        altitudeMeters: Double? = nil,
        speedMetersPerSecond: Double? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.altitudeMeters = altitudeMeters
        self.speedMetersPerSecond = speedMetersPerSecond
    }
}

public struct ChatMessagePayload: Codable, Sendable, Equatable {
    public let text: String
    public let coordinate: GeoCoordinate?

    public init(text: String, coordinate: GeoCoordinate? = nil) {
        self.text = text
        self.coordinate = coordinate
    }
}

public struct VoiceNotePayload: Codable, Sendable, Equatable {
    public let audioData: Data
    public let durationSeconds: Double
    public let transcriptText: String
    public let waveformSamples: [Float]
    public let coordinate: GeoCoordinate?

    public init(
        audioData: Data,
        durationSeconds: Double,
        transcriptText: String,
        waveformSamples: [Float] = [],
        coordinate: GeoCoordinate? = nil
    ) {
        self.audioData = audioData
        self.durationSeconds = durationSeconds
        self.transcriptText = transcriptText
        self.waveformSamples = waveformSamples
        self.coordinate = coordinate
    }
}

public struct HeartbeatPayload: Codable, Sendable, Equatable {
    public let identity: NodeIdentity
    public let directPeers: [NodeIdentity]
    public let coordinate: GeoCoordinate?

    public init(
        identity: NodeIdentity,
        directPeers: [NodeIdentity] = [],
        coordinate: GeoCoordinate? = nil
    ) {
        self.identity = identity
        self.directPeers = directPeers
        self.coordinate = coordinate
    }
}

public struct PingPayload: Codable, Sendable, Equatable {
    public let probeID: UUID
    public let originTimestampMs: Int64

    public init(probeID: UUID = UUID(), originTimestampMs: Int64) {
        self.probeID = probeID
        self.originTimestampMs = originTimestampMs
    }
}

public struct AckPayload: Codable, Sendable, Equatable {
    public let acknowledgedPacketID: UUID

    public init(acknowledgedPacketID: UUID) {
        self.acknowledgedPacketID = acknowledgedPacketID
    }
}

public struct SummaryVectorPayload: Codable, Sendable, Equatable {
    public let heldPacketIDs: [UUID]

    public init(heldPacketIDs: [UUID]) {
        self.heldPacketIDs = heldPacketIDs
    }
}

public struct PacketRequestPayload: Codable, Sendable, Equatable {
    public let missingPacketIDs: [UUID]

    public init(missingPacketIDs: [UUID]) {
        self.missingPacketIDs = missingPacketIDs
    }
}

// MARK: - Mesh Packet Envelope

public struct MeshPacket: Codable, Sendable, Identifiable, Equatable {
    public static let broadcastTarget = "ALL"
    public static let serviceType = "meshpulse"

    public let id: UUID
    public let type: PacketType
    public let senderID: String
    public let senderName: String
    public let targetID: String
    public var routePath: [String]
    public var routeNames: [String]
    public var ttl: Int
    public var remainingCopies: Int
    public let timestamp: Date
    public let isEncrypted: Bool
    public var senderPublicKeyBase64: String?
    public let payload: Data

    public init(
        id: UUID = UUID(),
        type: PacketType,
        senderID: String,
        senderName: String,
        targetID: String = MeshPacket.broadcastTarget,
        routePath: [String] = [],
        routeNames: [String] = [],
        ttl: Int = 4,
        remainingCopies: Int = 1,
        timestamp: Date = Date(),
        isEncrypted: Bool = false,
        senderPublicKeyBase64: String? = nil,
        payload: Data = Data()
    ) {
        self.id = id
        self.type = type
        self.senderID = senderID
        self.senderName = senderName
        self.targetID = targetID
        self.routePath = routePath
        self.routeNames = routeNames
        self.ttl = ttl
        self.remainingCopies = remainingCopies
        self.timestamp = timestamp
        self.isEncrypted = isEncrypted
        self.senderPublicKeyBase64 = senderPublicKeyBase64
        self.payload = payload
    }

    public var isBroadcast: Bool {
        targetID == Self.broadcastTarget
    }

    public var hopCount: Int {
        max(1, routePath.count)
    }
}

// MARK: - Topology, Delivery & Telemetry State

public enum LinkKind: Sendable, Equatable, Codable {
    case directP2P
    case relayedMesh(viaNodeID: String, viaDisplayName: String, hops: Int)
    case offlineDTN
}

public enum DeliveryState: String, Codable, Sendable, Equatable {
    case queuedDTN
    case sentDirect
    case relayed
    case deliveredAck
}

public struct PeerSummary: Identifiable, Sendable, Equatable, Codable {
    public var identity: NodeIdentity
    public var linkKind: LinkKind
    public var lastRTTMilliseconds: Int?
    public var lastSeen: Date
    public var trustState: PeerTrustState
    public var conflictPublicKeyBase64: String?
    public var lastCoordinate: GeoCoordinate?

    public var id: String { identity.nodeID }

    public init(
        identity: NodeIdentity,
        linkKind: LinkKind,
        lastRTTMilliseconds: Int? = nil,
        lastSeen: Date = Date(),
        trustState: PeerTrustState = .unverifiedTOFU,
        conflictPublicKeyBase64: String? = nil,
        lastCoordinate: GeoCoordinate? = nil
    ) {
        self.identity = identity
        self.linkKind = linkKind
        self.lastRTTMilliseconds = lastRTTMilliseconds
        self.lastSeen = lastSeen
        self.trustState = trustState
        self.conflictPublicKeyBase64 = conflictPublicKeyBase64
        self.lastCoordinate = lastCoordinate
    }
}

public struct TelemetrySnapshot: Sendable, Equatable, Codable {
    public var txPackets: Int
    public var rxPackets: Int
    public var relayedPackets: Int
    public var droppedDuplicates: Int
    public var blockedIngressDrops: Int
    public var rttSamplesMs: [Int]

    public init(
        txPackets: Int = 0,
        rxPackets: Int = 0,
        relayedPackets: Int = 0,
        droppedDuplicates: Int = 0,
        blockedIngressDrops: Int = 0,
        rttSamplesMs: [Int] = []
    ) {
        self.txPackets = txPackets
        self.rxPackets = rxPackets
        self.relayedPackets = relayedPackets
        self.droppedDuplicates = droppedDuplicates
        self.blockedIngressDrops = blockedIngressDrops
        self.rttSamplesMs = rttSamplesMs
    }

    public var averageRTTMs: Int? {
        guard !rttSamplesMs.isEmpty else { return nil }
        let total = rttSamplesMs.reduce(0, +)
        return total / rttSamplesMs.count
    }

    public mutating func recordRTT(_ ms: Int, maxSamples: Int = 50) {
        guard maxSamples > 0 else {
            rttSamplesMs.removeAll()
            return
        }
        rttSamplesMs.append(max(0, ms))
        if rttSamplesMs.count > maxSamples {
            rttSamplesMs = Array(rttSamplesMs.suffix(maxSamples))
        }
    }
}
