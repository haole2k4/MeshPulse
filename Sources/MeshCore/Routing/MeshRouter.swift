import Foundation

// MARK: - Router Output Value Types

public struct TopologyEdge: Identifiable, Sendable, Equatable {
    public let fromNodeID: String
    public let toNodeID: String
    public let isDirectP2P: Bool
    public let id: String

    public init(fromNodeID: String, toNodeID: String, isDirectP2P: Bool) {
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.isDirectP2P = isDirectP2P
        let canonicalPair =
            fromNodeID < toNodeID
            ? "\(fromNodeID)->\(toNodeID)"
            : "\(toNodeID)->\(fromNodeID)"
        self.id = "\(canonicalPair):\(isDirectP2P ? "direct" : "relay")"
    }
}

public struct ReceivedMeshMessage: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public let packetType: PacketType
    public let senderID: String
    public let senderName: String
    public let targetID: String
    public let text: String
    public let coordinate: GeoCoordinate?
    public let routePath: [String]
    public let routeNames: [String]
    public let hopCount: Int
    public let remainingTTL: Int
    public let isEncrypted: Bool
    public let timestamp: Date

    public init(
        id: UUID,
        packetType: PacketType,
        senderID: String,
        senderName: String,
        targetID: String,
        text: String,
        coordinate: GeoCoordinate?,
        routePath: [String],
        routeNames: [String],
        hopCount: Int,
        remainingTTL: Int,
        isEncrypted: Bool,
        timestamp: Date
    ) {
        self.id = id
        self.packetType = packetType
        self.senderID = senderID
        self.senderName = senderName
        self.targetID = targetID
        self.text = text
        self.coordinate = coordinate
        self.routePath = routePath
        self.routeNames = routeNames
        self.hopCount = hopCount
        self.remainingTTL = remainingTTL
        self.isEncrypted = isEncrypted
        self.timestamp = timestamp
    }
}

public enum PacketLogDirection: String, Sendable, Equatable, Codable {
    case tx
    case rx
    case relay
    case dropDuplicate
    case dropBlocked
    case dropTTL
}

public struct PacketLogEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let direction: PacketLogDirection
    public let packetType: PacketType
    public let packetID: UUID
    public let senderName: String
    public let targetID: String
    public let routeDisplay: String
    public let ttl: Int
    public let sizeBytes: Int
    public let rawJSON: String
    public let note: String

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        direction: PacketLogDirection,
        packetType: PacketType,
        packetID: UUID,
        senderName: String,
        targetID: String,
        routeDisplay: String,
        ttl: Int,
        sizeBytes: Int,
        rawJSON: String,
        note: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.direction = direction
        self.packetType = packetType
        self.packetID = packetID
        self.senderName = senderName
        self.targetID = targetID
        self.routeDisplay = routeDisplay
        self.ttl = ttl
        self.sizeBytes = sizeBytes
        self.rawJSON = rawJSON
        self.note = note
    }
}

public enum RouterEffect: Sendable, Equatable {
    case transmit(data: Data, packet: MeshPacket, toDirectPeerIDs: [String])
    case messageReceived(ReceivedMeshMessage)
    case deliveryUpdated(packetID: UUID, state: DeliveryState, routeNames: [String], rttMs: Int?)
    case pingCompleted(peerID: String, rttMs: Int, hops: Int)
    case packetLogged(PacketLogEntry)
}

// MARK: - Unified Mesh & DTN Router (Pure Value-State Engine)

public struct MeshRouter: Sendable {
    private struct LearnedRoute: Sendable, Equatable {
        var viaNodeID: String
        var viaDisplayName: String
        var hops: Int
        var lastSeen: Date
    }

    private struct PendingPing: Sendable {
        let targetID: String
        let sentAt: Date
    }

    public var localIdentity: NodeIdentity
    public var routingStrategy: RoutingStrategy
    public var initialSprayCopies: Int
    public var blockedPeerIDs: Set<String>
    public var seenCache: BoundedSeenCache
    public var dtnOutbox: DTNOutbox
    public var telemetry: TelemetrySnapshot

    private var rawDirectPeers: [String: NodeIdentity] = [:]
    private var knownPeerIdentities: [String: NodeIdentity] = [:]
    private var peerLastSeen: [String: Date] = [:]
    private var peerRTTMs: [String: Int] = [:]
    private var learnedRoutes: [String: LearnedRoute] = [:]
    private var heartbeatNeighborsByPeer: [String: [NodeIdentity]] = [:]
    private var pendingPings: [UUID: PendingPing] = [:]

    public init(
        localIdentity: NodeIdentity,
        routingStrategy: RoutingStrategy = .managedFlooding,
        initialSprayCopies: Int = 4,
        blockedPeerIDs: Set<String> = [],
        seenCache: BoundedSeenCache = BoundedSeenCache(),
        dtnOutbox: DTNOutbox = DTNOutbox(),
        telemetry: TelemetrySnapshot = TelemetrySnapshot()
    ) {
        self.localIdentity = localIdentity
        self.routingStrategy = routingStrategy
        self.initialSprayCopies = max(1, initialSprayCopies)
        self.blockedPeerIDs = blockedPeerIDs
        self.seenCache = seenCache
        self.dtnOutbox = dtnOutbox
        self.telemetry = telemetry
    }

    // MARK: - Topology Queries

    /// Direct 1-hop peers currently connected and NOT suppressed by `Topology Blocker`.
    public var activeDirectPeers: [NodeIdentity] {
        rawDirectPeers.values
            .filter { !blockedPeerIDs.contains($0.nodeID) && $0.nodeID != localIdentity.nodeID }
            .sorted { $0.nodeID < $1.nodeID }
    }

    public var activeDirectPeerIDs: Set<String> {
        Set(activeDirectPeers.map(\.nodeID))
    }

    public var knownPeers: [PeerSummary] {
        let activeIDs = activeDirectPeerIDs
        var summaries: [PeerSummary] = []

        for (peerID, identity) in knownPeerIdentities where peerID != localIdentity.nodeID {
            let linkKind: LinkKind
            if activeIDs.contains(peerID) {
                linkKind = .directP2P
            } else if let route = learnedRoutes[peerID], activeIDs.contains(route.viaNodeID) {
                linkKind = .relayedMesh(
                    viaNodeID: route.viaNodeID,
                    viaDisplayName: route.viaDisplayName,
                    hops: route.hops
                )
            } else {
                linkKind = .offlineDTN
            }

            summaries.append(
                PeerSummary(
                    identity: identity,
                    linkKind: linkKind,
                    lastRTTMilliseconds: peerRTTMs[peerID],
                    lastSeen: peerLastSeen[peerID] ?? .distantPast
                )
            )
        }

        return summaries.sorted { lhs, rhs in
            let lhsRank = Self.linkSortRank(lhs.linkKind)
            let rhsRank = Self.linkSortRank(rhs.linkKind)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.identity.displayName != rhs.identity.displayName {
                return lhs.identity.displayName < rhs.identity.displayName
            }
            return lhs.identity.nodeID < rhs.identity.nodeID
        }
    }

    public var topologyEdges: [TopologyEdge] {
        let activeIDs = activeDirectPeerIDs
        var byID: [String: TopologyEdge] = [:]

        for peerID in activeIDs {
            let edge = TopologyEdge(fromNodeID: localIdentity.nodeID, toNodeID: peerID, isDirectP2P: true)
            byID[edge.id] = edge
        }

        for (viaID, neighbors) in heartbeatNeighborsByPeer where activeIDs.contains(viaID) {
            for neighbor in neighbors where neighbor.nodeID != localIdentity.nodeID {
                if blockedPeerIDs.contains(neighbor.nodeID) || !activeIDs.contains(neighbor.nodeID) {
                    let edge = TopologyEdge(fromNodeID: viaID, toNodeID: neighbor.nodeID, isDirectP2P: false)
                    byID[edge.id] = edge
                }
            }
        }

        for (targetID, route) in learnedRoutes where activeIDs.contains(route.viaNodeID) && !activeIDs.contains(targetID) {
            let edge = TopologyEdge(fromNodeID: route.viaNodeID, toNodeID: targetID, isDirectP2P: false)
            if byID[edge.id] == nil {
                byID[edge.id] = edge
            }
        }

        return byID.values.sorted { $0.id < $1.id }
    }

    /// Pre-registers a known peer identity (e.g. out-of-band / QR public key or Mock Mode directory).
    public mutating func registerPeerIdentity(_ identity: NodeIdentity, lastSeen: Date? = nil) {
        guard identity.nodeID != localIdentity.nodeID else { return }
        knownPeerIdentities[identity.nodeID] = mergedIdentity(existing: knownPeerIdentities[identity.nodeID], incoming: identity)
        if let lastSeen {
            peerLastSeen[identity.nodeID] = max(peerLastSeen[identity.nodeID] ?? .distantPast, lastSeen)
        }
    }

    public mutating func broadcastHeartbeat(now: Date = Date()) -> [RouterEffect] {
        emitHeartbeat(to: Array(activeDirectPeerIDs).sorted(), now: now)
    }

    public mutating func updateLocalProfile(
        displayName: String? = nil,
        publicKeyBase64: String? = nil,
        now: Date = Date()
    ) -> [RouterEffect] {
        if let displayName, !displayName.isEmpty {
            localIdentity.displayName = displayName
        }
        if let publicKeyBase64 {
            localIdentity.publicKeyBase64 = publicKeyBase64
        }
        return broadcastHeartbeat(now: now)
    }

    public mutating func resetTelemetry() {
        telemetry = TelemetrySnapshot()
        pendingPings.removeAll()
    }

    // MARK: - Link & Topology Blocker Transitions

    public mutating func setPeerBlocked(
        _ peerID: String,
        isBlocked: Bool,
        now: Date = Date()
    ) -> [RouterEffect] {
        let previousActive = activeDirectPeerIDs
        if isBlocked {
            blockedPeerIDs.insert(peerID)
            heartbeatNeighborsByPeer.removeValue(forKey: peerID)
            learnedRoutes = learnedRoutes.filter { $0.value.viaNodeID != peerID }
        } else {
            blockedPeerIDs.remove(peerID)
        }
        return handleActivePeerTransition(previousActive: previousActive, now: now)
    }

    public mutating func updateDirectPeers(
        _ peers: [NodeIdentity],
        now: Date = Date()
    ) -> [RouterEffect] {
        let previousActive = activeDirectPeerIDs
        var nextRaw: [String: NodeIdentity] = [:]

        for peer in peers where peer.nodeID != localIdentity.nodeID {
            let merged = mergedIdentity(existing: knownPeerIdentities[peer.nodeID], incoming: peer)
            nextRaw[peer.nodeID] = merged
            knownPeerIdentities[peer.nodeID] = merged
            if !blockedPeerIDs.contains(peer.nodeID) {
                peerLastSeen[peer.nodeID] = now
            }
        }

        rawDirectPeers = nextRaw
        let currentActive = activeDirectPeerIDs
        heartbeatNeighborsByPeer = heartbeatNeighborsByPeer.filter { currentActive.contains($0.key) }
        learnedRoutes = learnedRoutes.filter { currentActive.contains($0.value.viaNodeID) }

        return handleActivePeerTransition(previousActive: previousActive, now: now)
    }

    private mutating func handleActivePeerTransition(
        previousActive: Set<String>,
        now: Date
    ) -> [RouterEffect] {
        dtnOutbox.pruneExpired(now: now)
        let currentActive = activeDirectPeerIDs
        let newlyJoined = currentActive.subtracting(previousActive).sorted()
        var effects: [RouterEffect] = []

        if currentActive != previousActive, !currentActive.isEmpty {
            effects.append(contentsOf: emitHeartbeat(to: Array(currentActive).sorted(), now: now))
        }

        for peerID in newlyJoined {
            effects.append(contentsOf: emitSummaryVector(to: peerID, now: now))
            effects.append(contentsOf: flushOutboxForPeer(peerID, now: now))
        }

        return effects
    }

    // MARK: - Outbound Origin Actions

    public mutating func sendChat(
        text: String,
        to targetID: String = MeshPacket.broadcastTarget,
        coordinate: GeoCoordinate? = nil,
        ttl: Int = 4,
        sealer: (any EnvelopeSealer)? = nil,
        recipientPublicKeyBase64: String? = nil,
        now: Date = Date()
    ) throws -> (packetID: UUID, effects: [RouterEffect]) {
        let clearPayload = ChatMessagePayload(text: text, coordinate: coordinate)
        let clearData = try Self.encodeJSON(clearPayload)

        let isBroadcast = (targetID == MeshPacket.broadcastTarget)
        let payloadData: Data
        let isEncrypted: Bool
        let senderPublicKeyBase64: String?

        if !isBroadcast, let sealer {
            let resolvedKey = recipientPublicKeyBase64 ?? knownPeerIdentities[targetID]?.publicKeyBase64
            guard let recipientKey = resolvedKey, !recipientKey.isEmpty else {
                throw MeshCryptoError.missingRecipientKey
            }
            payloadData = try sealer.seal(plaintext: clearData, recipientPublicKeyBase64: recipientKey)
            isEncrypted = true
            senderPublicKeyBase64 = sealer.publicKeyBase64
        } else {
            payloadData = clearData
            isEncrypted = false
            senderPublicKeyBase64 = nil
        }

        let copies = (!isBroadcast && routingStrategy == .sprayAndWait) ? initialSprayCopies : 1
        let packet = MeshPacket(
            type: .chat,
            senderID: localIdentity.nodeID,
            senderName: localIdentity.displayName,
            targetID: targetID,
            routePath: [localIdentity.nodeID],
            routeNames: [localIdentity.displayName],
            ttl: max(1, ttl),
            remainingCopies: copies,
            timestamp: now,
            isEncrypted: isEncrypted,
            senderPublicKeyBase64: senderPublicKeyBase64,
            payload: payloadData
        )

        let effects = try dispatchOriginChatOrSOS(packet: packet, now: now)
        return (packet.id, effects)
    }

    public mutating func sendSOS(
        text: String,
        coordinate: GeoCoordinate? = nil,
        ttl: Int = 6,
        now: Date = Date()
    ) throws -> (packetID: UUID, effects: [RouterEffect]) {
        let payloadData = try Self.encodeJSON(ChatMessagePayload(text: text, coordinate: coordinate))
        let packet = MeshPacket(
            type: .sos,
            senderID: localIdentity.nodeID,
            senderName: localIdentity.displayName,
            targetID: MeshPacket.broadcastTarget,
            routePath: [localIdentity.nodeID],
            routeNames: [localIdentity.displayName],
            ttl: max(1, ttl),
            remainingCopies: 1,
            timestamp: now,
            isEncrypted: false,
            payload: payloadData
        )
        let effects = try dispatchOriginChatOrSOS(packet: packet, now: now)
        return (packet.id, effects)
    }

    public mutating func sendPing(
        to targetID: String,
        ttl: Int = 4,
        now: Date = Date()
    ) throws -> (probeID: UUID, effects: [RouterEffect]) {
        let probeID = UUID()
        let originMs = Int64((now.timeIntervalSince1970 * 1000.0).rounded())
        let payloadData = try Self.encodeJSON(PingPayload(probeID: probeID, originTimestampMs: originMs))
        let packet = MeshPacket(
            id: probeID,
            type: .ping,
            senderID: localIdentity.nodeID,
            senderName: localIdentity.displayName,
            targetID: targetID,
            routePath: [localIdentity.nodeID],
            routeNames: [localIdentity.displayName],
            ttl: max(1, ttl),
            remainingCopies: 1,
            timestamp: now,
            isEncrypted: false,
            payload: payloadData
        )

        seenCache.insertIfNew(packet.id, now: now)
        pendingPings = pendingPings.filter { now.timeIntervalSince($0.value.sentAt) <= 60 }
        pendingPings[probeID] = PendingPing(targetID: targetID, sentAt: now)

        let recipients = selectUnicastNextHops(targetID: targetID, excluding: [])
        guard !recipients.isEmpty else {
            return (probeID, [])
        }
        let effects = try emitTransmission(
            packet: packet,
            toDirectPeerIDs: recipients,
            direction: .tx,
            note: "Gửi Ping tới \(targetID)",
            now: now
        )
        return (probeID, effects)
    }

    // MARK: - Inbound Packet Processing

    public mutating func handleIncoming(
        rawData: Data,
        fromDirectPeerID: String,
        sealer: (any EnvelopeSealer)? = nil,
        now: Date = Date()
    ) -> [RouterEffect] {
        let rawJSON = String(data: rawData, encoding: .utf8) ?? "<binary \(rawData.count)B>"

        // 1. CRITICAL: Topology Blocker ingress filter BEFORE touching seenCache!
        if blockedPeerIDs.contains(fromDirectPeerID) {
            telemetry.blockedIngressDrops += 1
            let decoded = try? Self.decodeJSON(MeshPacket.self, from: rawData)
            let entry = PacketLogEntry(
                timestamp: now,
                direction: .dropBlocked,
                packetType: decoded?.type ?? .chat,
                packetID: decoded?.id ?? UUID(),
                senderName: decoded?.senderName ?? fromDirectPeerID,
                targetID: decoded?.targetID ?? "?",
                routeDisplay: (decoded?.routeNames ?? [fromDirectPeerID]).joined(separator: " ➔ "),
                ttl: decoded?.ttl ?? 0,
                sizeBytes: rawData.count,
                rawJSON: rawJSON,
                note: "Chặn tại ngõ vào bởi Topology Blocker (\(fromDirectPeerID))"
            )
            return [.packetLogged(entry)]
        }

        guard let packet = try? Self.decodeJSON(MeshPacket.self, from: rawData) else {
            return []
        }

        // 2. BoundedSeenCache loop & duplicate suppression
        guard seenCache.insertIfNew(packet.id, now: now) else {
            telemetry.droppedDuplicates += 1
            let entry = makeLogEntry(
                packet: packet,
                rawData: rawData,
                rawJSON: rawJSON,
                direction: .dropDuplicate,
                note: "Loại bỏ gói trùng lặp qua BoundedSeenCache",
                now: now
            )
            return [.packetLogged(entry)]
        }

        telemetry.rxPackets += 1
        learnTopologyFromPacket(packet, fromDirectPeerID: fromDirectPeerID, now: now)

        var effects: [RouterEffect] = [
            .packetLogged(
                makeLogEntry(
                    packet: packet,
                    rawData: rawData,
                    rawJSON: rawJSON,
                    direction: .rx,
                    note: "Nhận từ \(fromDirectPeerID)",
                    now: now
                )
            )
        ]

        switch packet.type {
        case .heartbeat:
            effects.append(contentsOf: handleHeartbeat(packet, fromDirectPeerID: fromDirectPeerID, now: now))

        case .summaryVector:
            effects.append(contentsOf: handleSummaryVector(packet, fromDirectPeerID: fromDirectPeerID, now: now))

        case .packetRequest:
            effects.append(contentsOf: handlePacketRequest(packet, fromDirectPeerID: fromDirectPeerID, now: now))

        case .ack:
            effects.append(contentsOf: handleAck(packet, fromDirectPeerID: fromDirectPeerID, now: now))

        case .ping:
            effects.append(contentsOf: handlePing(packet, fromDirectPeerID: fromDirectPeerID, now: now))

        case .pong:
            effects.append(contentsOf: handlePong(packet, fromDirectPeerID: fromDirectPeerID, now: now))

        case .chat, .sos:
            effects.append(
                contentsOf: handleChatOrSOS(
                    packet,
                    rawData: rawData,
                    rawJSON: rawJSON,
                    fromDirectPeerID: fromDirectPeerID,
                    sealer: sealer,
                    now: now
                )
            )
        }

        return effects
    }

    // MARK: - Specific Packet Handlers

    private mutating func handleHeartbeat(
        _ packet: MeshPacket,
        fromDirectPeerID: String,
        now: Date
    ) -> [RouterEffect] {
        guard let hb = try? Self.decodeJSON(HeartbeatPayload.self, from: packet.payload) else {
            return []
        }

        let sender = mergedIdentity(existing: knownPeerIdentities[hb.identity.nodeID], incoming: hb.identity)
        knownPeerIdentities[sender.nodeID] = sender
        if rawDirectPeers[sender.nodeID] != nil {
            rawDirectPeers[sender.nodeID] = sender
        }
        peerLastSeen[sender.nodeID] = now

        guard activeDirectPeerIDs.contains(fromDirectPeerID), sender.nodeID == fromDirectPeerID else {
            return []
        }

        let previousRoutes = learnedRoutes
        heartbeatNeighborsByPeer[fromDirectPeerID] = hb.directPeers
        // Refresh 2-hop routes advertised by this neighbor
        learnedRoutes = learnedRoutes.filter { $0.value.viaNodeID != fromDirectPeerID }

        var newlyReachableTargets: [String] = []
        for neighbor in hb.directPeers where neighbor.nodeID != localIdentity.nodeID {
            knownPeerIdentities[neighbor.nodeID] = mergedIdentity(
                existing: knownPeerIdentities[neighbor.nodeID],
                incoming: neighbor
            )
            if !activeDirectPeerIDs.contains(neighbor.nodeID) {
                learnedRoutes[neighbor.nodeID] = LearnedRoute(
                    viaNodeID: fromDirectPeerID,
                    viaDisplayName: sender.displayName,
                    hops: 2,
                    lastSeen: now
                )
                if previousRoutes[neighbor.nodeID] == nil {
                    newlyReachableTargets.append(neighbor.nodeID)
                }
            }
        }

        var effects: [RouterEffect] = []
        if !newlyReachableTargets.isEmpty {
            effects.append(contentsOf: flushOutboxForLearnedTwoHop(viaPeerID: fromDirectPeerID, targets: Set(newlyReachableTargets), now: now))
        }
        return effects
    }

    private mutating func handleSummaryVector(
        _ packet: MeshPacket,
        fromDirectPeerID: String,
        now: Date
    ) -> [RouterEffect] {
        guard routingStrategy == .epidemic,
              activeDirectPeerIDs.contains(fromDirectPeerID),
              let sv = try? Self.decodeJSON(SummaryVectorPayload.self, from: packet.payload)
        else {
            return []
        }

        let missing = sv.heldPacketIDs.filter { id in
            !seenCache.contains(id, now: now) && dtnOutbox.record(for: id, now: now) == nil
        }
        guard !missing.isEmpty,
              let payloadData = try? Self.encodeJSON(PacketRequestPayload(missingPacketIDs: missing))
        else {
            return []
        }

        let requestPacket = MeshPacket(
            type: .packetRequest,
            senderID: localIdentity.nodeID,
            senderName: localIdentity.displayName,
            targetID: fromDirectPeerID,
            routePath: [localIdentity.nodeID],
            routeNames: [localIdentity.displayName],
            ttl: 1,
            remainingCopies: 1,
            timestamp: now,
            isEncrypted: false,
            payload: payloadData
        )
        seenCache.insertIfNew(requestPacket.id, now: now)
        return (try? emitTransmission(
            packet: requestPacket,
            toDirectPeerIDs: [fromDirectPeerID],
            direction: .tx,
            note: "Yêu cầu \(missing.count) gói DTN còn thiếu",
            now: now
        )) ?? []
    }

    private mutating func handlePacketRequest(
        _ packet: MeshPacket,
        fromDirectPeerID: String,
        now: Date
    ) -> [RouterEffect] {
        guard activeDirectPeerIDs.contains(fromDirectPeerID),
              let req = try? Self.decodeJSON(PacketRequestPayload.self, from: packet.payload)
        else {
            return []
        }

        var effects: [RouterEffect] = []
        let matchedPackets = dtnOutbox.packets(for: req.missingPacketIDs, now: now)

        for storedPacket in matchedPackets {
            // Respect Spray-and-Wait Wait-phase invariant even if requested explicitly
            if routingStrategy == .sprayAndWait,
               storedPacket.type == .chat,
               !storedPacket.isBroadcast,
               storedPacket.remainingCopies <= 1,
               storedPacket.targetID != fromDirectPeerID
            {
                continue
            }

            dtnOutbox.recordForwarded(packetID: storedPacket.id, toPeerID: fromDirectPeerID)
            let isRelay = storedPacket.senderID != localIdentity.nodeID
            if isRelay {
                telemetry.relayedPackets += 1
            } else if !storedPacket.isBroadcast, storedPacket.type == .chat {
                let state: DeliveryState = (fromDirectPeerID == storedPacket.targetID) ? .sentDirect : .relayed
                let routeNames = storedPacket.routeNames + [knownPeerIdentities[fromDirectPeerID]?.displayName ?? fromDirectPeerID]
                effects.append(.deliveryUpdated(packetID: storedPacket.id, state: state, routeNames: routeNames, rttMs: nil))
            }

            if let sent = try? emitTransmission(
                packet: storedPacket,
                toDirectPeerIDs: [fromDirectPeerID],
                direction: isRelay ? .relay : .tx,
                note: "Đồng bộ bù gói DTN theo PacketRequest",
                now: now
            ) {
                effects.append(contentsOf: sent)
            }
        }
        return effects
    }

    private mutating func handleAck(
        _ packet: MeshPacket,
        fromDirectPeerID: String,
        now: Date
    ) -> [RouterEffect] {
        guard let ack = try? Self.decodeJSON(AckPayload.self, from: packet.payload) else {
            return []
        }

        if packet.targetID == localIdentity.nodeID {
            let queuedAt = dtnOutbox.record(for: ack.acknowledgedPacketID, now: now)?.queuedAt
            let rttMs = queuedAt.map { max(0, Int((now.timeIntervalSince($0) * 1000.0).rounded())) }
            if let rttMs {
                telemetry.recordRTT(rttMs)
                peerRTTMs[packet.senderID] = rttMs
            }
            _ = dtnOutbox.markDelivered(packetID: ack.acknowledgedPacketID)
            let fullRoute = packet.routeNames + [localIdentity.displayName]
            return [
                .deliveryUpdated(
                    packetID: ack.acknowledgedPacketID,
                    state: .deliveredAck,
                    routeNames: fullRoute,
                    rttMs: rttMs
                )
            ]
        }

        // Antipacket / vaccine cleanup on intermediate carriers
        _ = dtnOutbox.markDelivered(packetID: ack.acknowledgedPacketID)
        return relayControlOrMessagePacket(packet, fromDirectPeerID: fromDirectPeerID, now: now)
    }

    private mutating func handlePing(
        _ packet: MeshPacket,
        fromDirectPeerID: String,
        now: Date
    ) -> [RouterEffect] {
        if packet.targetID == localIdentity.nodeID {
            guard let ping = try? Self.decodeJSON(PingPayload.self, from: packet.payload),
                  let pongData = try? Self.encodeJSON(ping)
            else {
                return []
            }

            let pongPacket = MeshPacket(
                type: .pong,
                senderID: localIdentity.nodeID,
                senderName: localIdentity.displayName,
                targetID: packet.senderID,
                routePath: [localIdentity.nodeID],
                routeNames: [localIdentity.displayName],
                ttl: 4,
                remainingCopies: 1,
                timestamp: now,
                isEncrypted: false,
                payload: pongData
            )
            seenCache.insertIfNew(pongPacket.id, now: now)

            var recipients = selectUnicastNextHops(targetID: packet.senderID, excluding: [])
            if fromDirectPeerID != packet.senderID,
               activeDirectPeerIDs.contains(fromDirectPeerID),
               !recipients.contains(fromDirectPeerID)
            {
                recipients.append(fromDirectPeerID)
            }
            guard !recipients.isEmpty else { return [] }
            return (try? emitTransmission(
                packet: pongPacket,
                toDirectPeerIDs: recipients,
                direction: .tx,
                note: "Phản hồi Pong về \(packet.senderName)",
                now: now
            )) ?? []
        }

        return relayControlOrMessagePacket(packet, fromDirectPeerID: fromDirectPeerID, now: now)
    }

    private mutating func handlePong(
        _ packet: MeshPacket,
        fromDirectPeerID: String,
        now: Date
    ) -> [RouterEffect] {
        if packet.targetID == localIdentity.nodeID {
            guard let pong = try? Self.decodeJSON(PingPayload.self, from: packet.payload) else {
                return []
            }
            let rttMs: Int
            if let pending = pendingPings.removeValue(forKey: pong.probeID) {
                rttMs = max(1, Int((now.timeIntervalSince(pending.sentAt) * 1000.0).rounded()))
            } else {
                let nowMs = Int64((now.timeIntervalSince1970 * 1000.0).rounded())
                rttMs = max(1, Int(nowMs - pong.originTimestampMs))
            }
            let hops = packet.hopCount
            telemetry.recordRTT(rttMs)
            peerRTTMs[packet.senderID] = rttMs
            return [.pingCompleted(peerID: packet.senderID, rttMs: rttMs, hops: hops)]
        }

        return relayControlOrMessagePacket(packet, fromDirectPeerID: fromDirectPeerID, now: now)
    }

    private mutating func handleChatOrSOS(
        _ packet: MeshPacket,
        rawData: Data,
        rawJSON: String,
        fromDirectPeerID: String,
        sealer: (any EnvelopeSealer)?,
        now: Date
    ) -> [RouterEffect] {
        var effects: [RouterEffect] = []
        let isForLocalNode = packet.isBroadcast || packet.targetID == localIdentity.nodeID

        if isForLocalNode {
            if let message = decodeReceivedMessage(packet: packet, sealer: sealer) {
                effects.append(.messageReceived(message))

                // Anti-ACK-Storm & E2EE Integrity rule: ONLY emit .ack after valid decryption + decoding!
                if packet.type == .chat, !packet.isBroadcast, packet.targetID == localIdentity.nodeID {
                    effects.append(
                        contentsOf: emitAck(
                            for: packet,
                            arrivedFromDirectPeerID: fromDirectPeerID,
                            now: now
                        )
                    )
                }
            }
        }

        // Unicast addressed strictly to us stops here; Broadcast / SOS or Unicast to another node relays on
        if packet.isBroadcast || packet.targetID != localIdentity.nodeID {
            effects.append(
                contentsOf: relayChatOrSOSPacket(
                    packet,
                    rawData: rawData,
                    rawJSON: rawJSON,
                    fromDirectPeerID: fromDirectPeerID,
                    now: now
                )
            )
        }

        return effects
    }

    // MARK: - Origin & Relay Routing Logic

    private mutating func dispatchOriginChatOrSOS(
        packet: MeshPacket,
        now: Date
    ) throws -> [RouterEffect] {
        seenCache.insertIfNew(packet.id, now: now)
        var effects: [RouterEffect] = []

        if packet.isBroadcast {
            let recipients = activeDirectPeers.map(\.nodeID)
            if routingStrategy == .epidemic {
                dtnOutbox.enqueue(packet, now: now, initialForwardedPeers: Set(recipients))
            }
            guard !recipients.isEmpty else {
                return effects
            }
            effects.append(
                contentsOf: try emitTransmission(
                    packet: packet,
                    toDirectPeerIDs: recipients,
                    direction: .tx,
                    note: "Phát quảng bá toàn mạng (\(packet.type.rawValue))",
                    now: now
                )
            )
            return effects
        }

        // 1-to-1 Direct Message: ALWAYS persist in DTNOutbox until .ack arrives
        let activeIDs = activeDirectPeerIDs

        // Case 1: Target is a 1-hop active direct peer -> Unicast directly in ALL strategies
        if activeIDs.contains(packet.targetID) {
            dtnOutbox.enqueue(packet, now: now, initialForwardedPeers: [packet.targetID])
            let targetName = knownPeerIdentities[packet.targetID]?.displayName ?? packet.targetID
            effects.append(
                .deliveryUpdated(
                    packetID: packet.id,
                    state: .sentDirect,
                    routeNames: [localIdentity.displayName, targetName],
                    rttMs: nil
                )
            )
            effects.append(
                contentsOf: try emitTransmission(
                    packet: packet,
                    toDirectPeerIDs: [packet.targetID],
                    direction: .tx,
                    note: "Gửi trực tiếp 1-Hop tới \(targetName)",
                    now: now
                )
            )
            return effects
        }

        // Case 2: No active direct peers -> queue in DTNOutbox (.queuedDTN)
        if activeIDs.isEmpty {
            dtnOutbox.enqueue(packet, now: now)
            effects.append(
                .deliveryUpdated(
                    packetID: packet.id,
                    state: .queuedDTN,
                    routeNames: [localIdentity.displayName],
                    rttMs: nil
                )
            )
            return effects
        }

        // Case 3: Strategy-specific multi-hop / DTN dispatch across active neighbors
        switch routingStrategy {
        case .sprayAndWait:
            let preferredVia = learnedRoutes[packet.targetID]?.viaNodeID
            let candidate: String? =
                if let preferredVia, activeIDs.contains(preferredVia) {
                    preferredVia
                } else {
                    activeDirectPeers.first?.nodeID
                }

            guard let chosenPeer = candidate, packet.remainingCopies > 1 else {
                dtnOutbox.enqueue(packet, now: now)
                effects.append(
                    .deliveryUpdated(
                        packetID: packet.id,
                        state: .queuedDTN,
                        routeNames: [localIdentity.displayName],
                        rttMs: nil
                    )
                )
                return effects
            }

            let forwardedCopies = packet.remainingCopies / 2
            let keptCopies = packet.remainingCopies - forwardedCopies

            var localStored = packet
            localStored.remainingCopies = keptCopies
            dtnOutbox.enqueue(localStored, now: now, initialForwardedPeers: [chosenPeer])

            var wirePacket = packet
            wirePacket.remainingCopies = forwardedCopies
            let viaName = knownPeerIdentities[chosenPeer]?.displayName ?? chosenPeer
            effects.append(
                .deliveryUpdated(
                    packetID: packet.id,
                    state: .relayed,
                    routeNames: [localIdentity.displayName, viaName],
                    rttMs: nil
                )
            )
            effects.append(
                contentsOf: try emitTransmission(
                    packet: wirePacket,
                    toDirectPeerIDs: [chosenPeer],
                    direction: .tx,
                    note: "Spray-and-Wait phun \(forwardedCopies) bản sao qua \(viaName) (giữ \(keptCopies))",
                    now: now
                )
            )
            return effects

        case .epidemic:
            // If we have a live 2-hop route right now, forward immediately AND store; otherwise store & announce SummaryVector
            if let route = learnedRoutes[packet.targetID], activeIDs.contains(route.viaNodeID) {
                dtnOutbox.enqueue(packet, now: now, initialForwardedPeers: [route.viaNodeID])
                effects.append(
                    .deliveryUpdated(
                        packetID: packet.id,
                        state: .relayed,
                        routeNames: [localIdentity.displayName, route.viaDisplayName],
                        rttMs: nil
                    )
                )
                effects.append(
                    contentsOf: try emitTransmission(
                        packet: packet,
                        toDirectPeerIDs: [route.viaNodeID],
                        direction: .tx,
                        note: "Chuyển tiếp 2-Hop qua \(route.viaDisplayName)",
                        now: now
                    )
                )
            } else {
                dtnOutbox.enqueue(packet, now: now)
                effects.append(
                    .deliveryUpdated(
                        packetID: packet.id,
                        state: .queuedDTN,
                        routeNames: [localIdentity.displayName],
                        rttMs: nil
                    )
                )
                for peer in activeDirectPeers {
                    effects.append(contentsOf: emitSummaryVector(to: peer.nodeID, now: now))
                }
            }
            return effects

        case .managedFlooding:
            let recipients = selectUnicastNextHops(targetID: packet.targetID, excluding: [])
            dtnOutbox.enqueue(packet, now: now, initialForwardedPeers: Set(recipients))
            let viaNames = recipients.prefix(1).map { knownPeerIdentities[$0]?.displayName ?? $0 }
            effects.append(
                .deliveryUpdated(
                    packetID: packet.id,
                    state: .relayed,
                    routeNames: [localIdentity.displayName] + viaNames,
                    rttMs: nil
                )
            )
            effects.append(
                contentsOf: try emitTransmission(
                    packet: packet,
                    toDirectPeerIDs: recipients,
                    direction: .tx,
                    note: "Định tuyến bắc cầu tới \(packet.targetID)",
                    now: now
                )
            )
            return effects
        }
    }

    private mutating func relayChatOrSOSPacket(
        _ packet: MeshPacket,
        rawData: Data,
        rawJSON: String,
        fromDirectPeerID: String,
        now: Date
    ) -> [RouterEffect] {
        guard packet.ttl > 1 else {
            let dropEntry = makeLogEntry(
                packet: packet,
                rawData: rawData,
                rawJSON: rawJSON,
                direction: .dropTTL,
                note: "Hết ngân sách bước nhảy (TTL <= 1)",
                now: now
            )
            return [.packetLogged(dropEntry)]
        }

        var relayed = packet
        relayed.ttl -= 1
        relayed.routePath.append(localIdentity.nodeID)
        relayed.routeNames.append(localIdentity.displayName)

        let activeIDs = activeDirectPeerIDs

        // Fast-path: Target is an active 1-hop neighbor of this relay (works even in Spray-and-Wait Wait phase!)
        if !relayed.isBroadcast, activeIDs.contains(relayed.targetID) {
            if routingStrategy == .epidemic {
                dtnOutbox.enqueue(relayed, now: now, initialForwardedPeers: [fromDirectPeerID, relayed.targetID])
            }
            telemetry.relayedPackets += 1
            return (try? emitTransmission(
                packet: relayed,
                toDirectPeerIDs: [relayed.targetID],
                direction: .relay,
                note: "Bắc cầu đích danh 1-Hop cuối tới \(relayed.targetID)",
                now: now
            )) ?? []
        }

        // Binary Spray-and-Wait for 1-to-1 chat
        if routingStrategy == .sprayAndWait, relayed.type == .chat, !relayed.isBroadcast {
            let candidates = activeDirectPeers
                .map(\.nodeID)
                .filter { $0 != fromDirectPeerID && !relayed.routePath.contains($0) }

            if relayed.remainingCopies > 1, let nextPeer = candidates.first {
                let forwardedCopies = relayed.remainingCopies / 2
                let keptCopies = relayed.remainingCopies - forwardedCopies

                var storedCopy = relayed
                storedCopy.remainingCopies = keptCopies
                dtnOutbox.enqueue(storedCopy, now: now, initialForwardedPeers: [fromDirectPeerID, nextPeer])

                var wireCopy = relayed
                wireCopy.remainingCopies = forwardedCopies
                telemetry.relayedPackets += 1
                return (try? emitTransmission(
                    packet: wireCopy,
                    toDirectPeerIDs: [nextPeer],
                    direction: .relay,
                    note: "Spray-and-Wait chuyển \(forwardedCopies) bản sao cho \(nextPeer) (giữ \(keptCopies))",
                    now: now
                )) ?? []
            } else {
                // Either remainingCopies == 1 (Wait phase) or no candidate neighbor yet: hold in DTNOutbox!
                dtnOutbox.enqueue(relayed, now: now, initialForwardedPeers: [fromDirectPeerID])
                return []
            }
        }

        // Epidemic Store-and-Forward: cache relayed copy so future encounters reconcile via SummaryVector
        if routingStrategy == .epidemic {
            let excluded = Set(relayed.routePath).union([fromDirectPeerID])
            let recipients: [String]
            if relayed.isBroadcast {
                recipients = activeDirectPeers.map(\.nodeID).filter { !excluded.contains($0) }
            } else {
                recipients = selectUnicastNextHops(targetID: relayed.targetID, excluding: excluded)
            }
            dtnOutbox.enqueue(relayed, now: now, initialForwardedPeers: Set(recipients).union([fromDirectPeerID]))
            guard !recipients.isEmpty else {
                return []
            }
            telemetry.relayedPackets += 1
            return (try? emitTransmission(
                packet: relayed,
                toDirectPeerIDs: recipients,
                direction: .relay,
                note: "Bắc cầu Epidemic qua \(recipients.joined(separator: ", "))",
                now: now
            )) ?? []
        }

        // Managed Flooding / SOS / Broadcast
        let excluded = Set(relayed.routePath).union([fromDirectPeerID])
        let recipients: [String]
        if relayed.isBroadcast {
            recipients = activeDirectPeers.map(\.nodeID).filter { !excluded.contains($0) }
        } else {
            recipients = selectUnicastNextHops(targetID: relayed.targetID, excluding: excluded)
        }

        guard !recipients.isEmpty else { return [] }
        telemetry.relayedPackets += 1
        return (try? emitTransmission(
            packet: relayed,
            toDirectPeerIDs: recipients,
            direction: .relay,
            note: "Chuyển tiếp gói tin (\(relayed.type.rawValue))",
            now: now
        )) ?? []
    }

    private mutating func relayControlOrMessagePacket(
        _ packet: MeshPacket,
        fromDirectPeerID: String,
        now: Date
    ) -> [RouterEffect] {
        let rawData = (try? Self.encodeJSON(packet)) ?? Data()
        let rawJSON = String(data: rawData, encoding: .utf8) ?? ""

        guard packet.ttl > 1 else {
            let dropEntry = makeLogEntry(
                packet: packet,
                rawData: rawData,
                rawJSON: rawJSON,
                direction: .dropTTL,
                note: "Hết ngân sách bước nhảy (TTL <= 1)",
                now: now
            )
            return [.packetLogged(dropEntry)]
        }

        var relayed = packet
        relayed.ttl -= 1
        relayed.routePath.append(localIdentity.nodeID)
        relayed.routeNames.append(localIdentity.displayName)

        let excluded = Set(relayed.routePath).union([fromDirectPeerID])
        let recipients = selectUnicastNextHops(targetID: relayed.targetID, excluding: excluded)

        guard !recipients.isEmpty else {
            if routingStrategy == .epidemic, relayed.type == .ack {
                dtnOutbox.enqueue(relayed, now: now, initialForwardedPeers: [fromDirectPeerID])
            }
            return []
        }

        telemetry.relayedPackets += 1
        return (try? emitTransmission(
            packet: relayed,
            toDirectPeerIDs: recipients,
            direction: .relay,
            note: "Bắc cầu tín hiệu điều khiển (\(relayed.type.rawValue))",
            now: now
        )) ?? []
    }

    // MARK: - DTN Outbox Flushing & Control Packets

    private mutating func flushOutboxForPeer(
        _ peerID: String,
        now: Date
    ) -> [RouterEffect] {
        // In Epidemic mode, peer synchronization is driven via SummaryVector + PacketRequest
        guard routingStrategy != .epidemic else {
            return []
        }

        var effects: [RouterEffect] = []
        let records = dtnOutbox.allRecords(now: now).reversed()

        for record in records {
            let pkt = record.packet
            guard !record.forwardedPeers.contains(peerID),
                  !pkt.routePath.contains(peerID)
            else {
                continue
            }

            let isOrigin = (pkt.senderID == localIdentity.nodeID)

            // 1. Direct target encounter (delivers immediately even in Spray-and-Wait Wait phase!)
            if pkt.targetID == peerID {
                dtnOutbox.recordForwarded(packetID: pkt.id, toPeerID: peerID)
                if isOrigin {
                    let targetName = knownPeerIdentities[peerID]?.displayName ?? peerID
                    effects.append(
                        .deliveryUpdated(
                            packetID: pkt.id,
                            state: .sentDirect,
                            routeNames: [localIdentity.displayName, targetName],
                            rttMs: nil
                        )
                    )
                } else {
                    telemetry.relayedPackets += 1
                }
                if let sent = try? emitTransmission(
                    packet: pkt,
                    toDirectPeerIDs: [peerID],
                    direction: isOrigin ? .tx : .relay,
                    note: "Đẩy gói DTN trực tiếp cho đích \(peerID)",
                    now: now
                ) {
                    effects.append(contentsOf: sent)
                }
                continue
            }

            // 2. Intermediate encounter in Spray-and-Wait
            if routingStrategy == .sprayAndWait, pkt.type == .chat, !pkt.isBroadcast {
                guard pkt.remainingCopies > 1 else {
                    // Wait phase (remainingCopies == 1): hold for direct target encounter only!
                    continue
                }
                let forwardedCopies = pkt.remainingCopies / 2
                let keptCopies = pkt.remainingCopies - forwardedCopies
                dtnOutbox.recordForwarded(packetID: pkt.id, toPeerID: peerID, remainingCopies: keptCopies)

                var wireCopy = pkt
                wireCopy.remainingCopies = forwardedCopies
                if isOrigin {
                    let viaName = knownPeerIdentities[peerID]?.displayName ?? peerID
                    effects.append(
                        .deliveryUpdated(
                            packetID: pkt.id,
                            state: .relayed,
                            routeNames: [localIdentity.displayName, viaName],
                            rttMs: nil
                        )
                    )
                } else {
                    telemetry.relayedPackets += 1
                }
                if let sent = try? emitTransmission(
                    packet: wireCopy,
                    toDirectPeerIDs: [peerID],
                    direction: isOrigin ? .tx : .relay,
                    note: "Spray-and-Wait phun \(forwardedCopies) bản sao cho \(peerID) (giữ \(keptCopies))",
                    now: now
                ) {
                    effects.append(contentsOf: sent)
                }
                continue
            }

            // 3. Managed Flooding opportunistic push
            if routingStrategy == .managedFlooding {
                dtnOutbox.recordForwarded(packetID: pkt.id, toPeerID: peerID)
                if isOrigin, !pkt.isBroadcast {
                    let viaName = knownPeerIdentities[peerID]?.displayName ?? peerID
                    effects.append(
                        .deliveryUpdated(
                            packetID: pkt.id,
                            state: .relayed,
                            routeNames: [localIdentity.displayName, viaName],
                            rttMs: nil
                        )
                    )
                } else if !isOrigin {
                    telemetry.relayedPackets += 1
                }
                if let sent = try? emitTransmission(
                    packet: pkt,
                    toDirectPeerIDs: [peerID],
                    direction: isOrigin ? .tx : .relay,
                    note: "Đẩy gói DTN qua láng giềng mới \(peerID)",
                    now: now
                ) {
                    effects.append(contentsOf: sent)
                }
            }
        }

        return effects
    }

    private mutating func flushOutboxForLearnedTwoHop(
        viaPeerID: String,
        targets: Set<String>,
        now: Date
    ) -> [RouterEffect] {
        guard routingStrategy == .managedFlooding else { return [] }
        var effects: [RouterEffect] = []

        for record in dtnOutbox.allRecords(now: now).reversed() {
            let pkt = record.packet
            guard targets.contains(pkt.targetID),
                  !record.forwardedPeers.contains(viaPeerID),
                  !pkt.routePath.contains(viaPeerID)
            else {
                continue
            }

            dtnOutbox.recordForwarded(packetID: pkt.id, toPeerID: viaPeerID)
            let isOrigin = (pkt.senderID == localIdentity.nodeID)
            if isOrigin {
                let viaName = knownPeerIdentities[viaPeerID]?.displayName ?? viaPeerID
                effects.append(
                    .deliveryUpdated(
                        packetID: pkt.id,
                        state: .relayed,
                        routeNames: [localIdentity.displayName, viaName],
                        rttMs: nil
                    )
                )
            } else {
                telemetry.relayedPackets += 1
            }

            if let sent = try? emitTransmission(
                packet: pkt,
                toDirectPeerIDs: [viaPeerID],
                direction: isOrigin ? .tx : .relay,
                note: "Đẩy gói DTN qua tuyến 2-Hop \(viaPeerID)",
                now: now
            ) {
                effects.append(contentsOf: sent)
            }
        }
        return effects
    }

    private mutating func emitHeartbeat(
        to recipients: [String],
        now: Date
    ) -> [RouterEffect] {
        guard !recipients.isEmpty,
              let payloadData = try? Self.encodeJSON(
                  HeartbeatPayload(identity: localIdentity, directPeers: activeDirectPeers)
              )
        else {
            return []
        }

        let hbPacket = MeshPacket(
            type: .heartbeat,
            senderID: localIdentity.nodeID,
            senderName: localIdentity.displayName,
            targetID: MeshPacket.broadcastTarget,
            routePath: [localIdentity.nodeID],
            routeNames: [localIdentity.displayName],
            ttl: 1,
            remainingCopies: 1,
            timestamp: now,
            isEncrypted: false,
            payload: payloadData
        )
        seenCache.insertIfNew(hbPacket.id, now: now)
        return (try? emitTransmission(
            packet: hbPacket,
            toDirectPeerIDs: recipients,
            direction: .tx,
            note: "Phát Heartbeat láng giềng 1-Hop",
            now: now
        )) ?? []
    }

    private mutating func emitSummaryVector(
        to peerID: String,
        now: Date
    ) -> [RouterEffect] {
        let heldIDs = dtnOutbox.summaryVector(now: now)
        guard let payloadData = try? Self.encodeJSON(SummaryVectorPayload(heldPacketIDs: heldIDs)) else {
            return []
        }

        let svPacket = MeshPacket(
            type: .summaryVector,
            senderID: localIdentity.nodeID,
            senderName: localIdentity.displayName,
            targetID: peerID,
            routePath: [localIdentity.nodeID],
            routeNames: [localIdentity.displayName],
            ttl: 1,
            remainingCopies: 1,
            timestamp: now,
            isEncrypted: false,
            payload: payloadData
        )
        seenCache.insertIfNew(svPacket.id, now: now)
        return (try? emitTransmission(
            packet: svPacket,
            toDirectPeerIDs: [peerID],
            direction: .tx,
            note: "Trao đổi Summary Vector (\(heldIDs.count) gói)",
            now: now
        )) ?? []
    }

    private mutating func emitAck(
        for packet: MeshPacket,
        arrivedFromDirectPeerID: String,
        now: Date
    ) -> [RouterEffect] {
        guard let ackData = try? Self.encodeJSON(AckPayload(acknowledgedPacketID: packet.id)) else {
            return []
        }

        let ackPacket = MeshPacket(
            type: .ack,
            senderID: localIdentity.nodeID,
            senderName: localIdentity.displayName,
            targetID: packet.senderID,
            routePath: [localIdentity.nodeID],
            routeNames: [localIdentity.displayName],
            ttl: 6,
            remainingCopies: 1,
            timestamp: now,
            isEncrypted: false,
            payload: ackData
        )
        seenCache.insertIfNew(ackPacket.id, now: now)

        var recipients = selectUnicastNextHops(targetID: packet.senderID, excluding: [])
        // If message arrived via a relay despite sender appearing in activeDirectPeers (asymmetric blocker on sender),
        // also include the relay neighbor so ACK returns reliably via the working relay path!
        if arrivedFromDirectPeerID != packet.senderID,
           activeDirectPeerIDs.contains(arrivedFromDirectPeerID),
           !recipients.contains(arrivedFromDirectPeerID)
        {
            recipients.append(arrivedFromDirectPeerID)
        }

        if recipients.isEmpty {
            if routingStrategy == .epidemic {
                dtnOutbox.enqueue(ackPacket, now: now)
            }
            return []
        }

        return (try? emitTransmission(
            packet: ackPacket,
            toDirectPeerIDs: recipients,
            direction: .tx,
            note: "Gửi biên nhận ACK cho gói \(packet.id.uuidString.prefix(8))",
            now: now
        )) ?? []
    }

    // MARK: - Helpers

    private func selectUnicastNextHops(
        targetID: String,
        excluding excluded: Set<String>
    ) -> [String] {
        let activeIDs = activeDirectPeerIDs
        if activeIDs.contains(targetID), !excluded.contains(targetID) {
            return [targetID]
        }
        if let route = learnedRoutes[targetID],
           activeIDs.contains(route.viaNodeID),
           !excluded.contains(route.viaNodeID)
        {
            return [route.viaNodeID]
        }
        return activeDirectPeers
            .map(\.nodeID)
            .filter { !excluded.contains($0) }
    }

    private mutating func learnTopologyFromPacket(
        _ packet: MeshPacket,
        fromDirectPeerID: String,
        now: Date
    ) {
        peerLastSeen[fromDirectPeerID] = now
        if packet.senderID != localIdentity.nodeID {
            let incomingKey =
                (packet.senderPublicKeyBase64?.isEmpty == false)
                ? packet.senderPublicKeyBase64
                : nil
            let senderIdentity = NodeIdentity(
                nodeID: packet.senderID,
                displayName: packet.senderName,
                publicKeyBase64: incomingKey
            )
            knownPeerIdentities[packet.senderID] = mergedIdentity(
                existing: knownPeerIdentities[packet.senderID],
                incoming: senderIdentity
            )
            peerLastSeen[packet.senderID] = now

            if !activeDirectPeerIDs.contains(packet.senderID),
               activeDirectPeerIDs.contains(fromDirectPeerID)
            {
                let viaName = knownPeerIdentities[fromDirectPeerID]?.displayName ?? fromDirectPeerID
                learnedRoutes[packet.senderID] = LearnedRoute(
                    viaNodeID: fromDirectPeerID,
                    viaDisplayName: viaName,
                    hops: max(2, packet.hopCount),
                    lastSeen: now
                )
            }
        }
    }

    private func decodeReceivedMessage(
        packet: MeshPacket,
        sealer: (any EnvelopeSealer)?
    ) -> ReceivedMeshMessage? {
        let clearBytes: Data
        if packet.isEncrypted {
            let pinnedKey = knownPeerIdentities[packet.senderID]?.publicKeyBase64
            let effectiveSenderKey =
                ((pinnedKey?.isEmpty == false) ? pinnedKey : nil)
                ?? packet.senderPublicKeyBase64
            guard let sealer,
                  let senderPubKey = effectiveSenderKey,
                  !senderPubKey.isEmpty,
                  let opened = try? sealer.open(ciphertext: packet.payload, senderPublicKeyBase64: senderPubKey)
            else {
                return nil
            }
            clearBytes = opened
        } else {
            clearBytes = packet.payload
        }

        guard let chat = try? Self.decodeJSON(ChatMessagePayload.self, from: clearBytes) else {
            return nil
        }

        let fullRoutePath =
            packet.routePath.last == localIdentity.nodeID
            ? packet.routePath
            : packet.routePath + [localIdentity.nodeID]
        let fullRouteNames =
            packet.routeNames.last == localIdentity.displayName
            ? packet.routeNames
            : packet.routeNames + [localIdentity.displayName]

        return ReceivedMeshMessage(
            id: packet.id,
            packetType: packet.type,
            senderID: packet.senderID,
            senderName: packet.senderName,
            targetID: packet.targetID,
            text: chat.text,
            coordinate: chat.coordinate,
            routePath: fullRoutePath,
            routeNames: fullRouteNames,
            hopCount: packet.hopCount,
            remainingTTL: packet.ttl,
            isEncrypted: packet.isEncrypted,
            timestamp: packet.timestamp
        )
    }

    private mutating func emitTransmission(
        packet: MeshPacket,
        toDirectPeerIDs recipients: [String],
        direction: PacketLogDirection,
        note: String,
        now: Date
    ) throws -> [RouterEffect] {
        guard !recipients.isEmpty else { return [] }
        let wireData = try Self.encodeJSON(packet)
        let rawJSON = String(data: wireData, encoding: .utf8) ?? ""
        if direction == .tx {
            telemetry.txPackets += 1
        }
        let logEntry = makeLogEntry(
            packet: packet,
            rawData: wireData,
            rawJSON: rawJSON,
            direction: direction,
            note: note,
            now: now
        )
        return [
            .packetLogged(logEntry),
            .transmit(data: wireData, packet: packet, toDirectPeerIDs: recipients),
        ]
    }

    private func makeLogEntry(
        packet: MeshPacket,
        rawData: Data,
        rawJSON: String,
        direction: PacketLogDirection,
        note: String,
        now: Date
    ) -> PacketLogEntry {
        PacketLogEntry(
            timestamp: now,
            direction: direction,
            packetType: packet.type,
            packetID: packet.id,
            senderName: packet.senderName,
            targetID: packet.targetID,
            routeDisplay: packet.routeNames.joined(separator: " ➔ "),
            ttl: packet.ttl,
            sizeBytes: rawData.count,
            rawJSON: rawJSON,
            note: note
        )
    }

    private func mergedIdentity(existing: NodeIdentity?, incoming: NodeIdentity) -> NodeIdentity {
        guard let existing else { return incoming }
        let existingKey = (existing.publicKeyBase64?.isEmpty == false) ? existing.publicKeyBase64 : nil
        let incomingKey = (incoming.publicKeyBase64?.isEmpty == false) ? incoming.publicKeyBase64 : nil
        return NodeIdentity(
            nodeID: incoming.nodeID,
            displayName: incoming.displayName.isEmpty ? existing.displayName : incoming.displayName,
            // TOFU (Trust On First Use): never overwrite an already-pinned public key
            publicKeyBase64: existingKey ?? incomingKey
        )
    }

    private static func linkSortRank(_ kind: LinkKind) -> Int {
        switch kind {
        case .directP2P: 0
        case .relayedMesh: 1
        case .offlineDTN: 2
        }
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}
