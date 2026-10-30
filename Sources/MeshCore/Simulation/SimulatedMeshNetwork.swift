import Foundation

public struct CompletedPingRecord: Sendable, Equatable {
    public let peerID: String
    public let rttMs: Int
    public let hops: Int

    public init(peerID: String, rttMs: Int, hops: Int) {
        self.peerID = peerID
        self.rttMs = rttMs
        self.hops = hops
    }
}

public struct SimulatedNodeState: Sendable {
    public var router: MeshRouter
    public let sealer: SimulatedEnvelopeSealer
    public var receivedMessages: [ReceivedMeshMessage] = []
    public var deliveryStates: [UUID: DeliveryState] = [:]
    public var deliveryRoutes: [UUID: [String]] = [:]
    public var deliveryRTTMs: [UUID: Int] = [:]
    public var completedPings: [CompletedPingRecord] = []
    public var packetLogs: [PacketLogEntry] = []

    public var identity: NodeIdentity {
        router.localIdentity
    }

    public init(router: MeshRouter, sealer: SimulatedEnvelopeSealer) {
        self.router = router
        self.sealer = sealer
    }
}

public struct SimulatedWireFrame: Sendable, Equatable {
    public let sequenceNumber: UInt64
    public let fromNodeID: String
    public let toNodeID: String
    public let data: Data
    public let packet: MeshPacket
    public let deliverAt: Date
}

/// Deterministic in-memory multi-node mesh & DTN simulator.
///
/// Used both by Linux `Swift Testing` suites (`MeshRouterTests`) and by the iOS UI's
/// interactive **Mock Mode** (`iPhone-A`, `iPhone-B`, `iPhone-C`).
public struct SimulatedMeshNetwork: Sendable {
    public static let nodeAID = "iPhone-A"
    public static let nodeBID = "iPhone-B"
    public static let nodeCID = "iPhone-C"

    private struct UndirectedLink: Hashable, Sendable {
        let low: String
        let high: String

        init(_ a: String, _ b: String) {
            if a < b {
                self.low = a
                self.high = b
            } else {
                self.low = b
                self.high = a
            }
        }

        func other(_ id: String) -> String? {
            if id == low { return high }
            if id == high { return low }
            return nil
        }
    }

    public private(set) var currentTime: Date
    public var hopLatency: TimeInterval
    public var autoReplyEnabled: Bool

    private var nodesByID: [String: SimulatedNodeState] = [:]
    private var orderedNodeIDs: [String] = []
    private var physicalLinks: Set<UndirectedLink> = []
    private var wireQueue: [SimulatedWireFrame] = []
    private var nextSequenceNumber: UInt64 = 1
    private var autoRepliedPacketIDs: Set<UUID> = []

    /// Creates the default 3-node triangle (`iPhone-A`, `iPhone-B`, `iPhone-C`) connected `A—B`, `B—C`, `A—C`.
    public init(
        routingStrategy: RoutingStrategy = .managedFlooding,
        initialSprayCopies: Int = 4,
        hopLatency: TimeInterval = 0.012,
        autoReplyEnabled: Bool = false,
        startTime: Date = Date(timeIntervalSince1970: 1_730_300_000)
    ) {
        self.init(
            nodeSpecs: [
                (Self.nodeAID, "iPhone-A", "seed-iphone-a"),
                (Self.nodeBID, "iPhone-B", "seed-iphone-b"),
                (Self.nodeCID, "iPhone-C", "seed-iphone-c"),
            ],
            initialLinks: [
                (Self.nodeAID, Self.nodeBID),
                (Self.nodeBID, Self.nodeCID),
                (Self.nodeAID, Self.nodeCID),
            ],
            routingStrategy: routingStrategy,
            initialSprayCopies: initialSprayCopies,
            hopLatency: hopLatency,
            autoReplyEnabled: autoReplyEnabled,
            startTime: startTime
        )
    }

    /// Creates a custom multi-node network topology.
    public init(
        nodeSpecs: [(nodeID: String, displayName: String, seed: String)],
        initialLinks: [(String, String)] = [],
        routingStrategy: RoutingStrategy = .managedFlooding,
        initialSprayCopies: Int = 4,
        hopLatency: TimeInterval = 0.012,
        autoReplyEnabled: Bool = false,
        startTime: Date = Date(timeIntervalSince1970: 1_730_300_000)
    ) {
        self.currentTime = startTime
        self.hopLatency = max(0.001, hopLatency)
        self.autoReplyEnabled = autoReplyEnabled

        for spec in nodeSpecs {
            addNode(
                nodeID: spec.nodeID,
                displayName: spec.displayName,
                seed: spec.seed,
                routingStrategy: routingStrategy,
                initialSprayCopies: initialSprayCopies
            )
        }

        for (lhs, rhs) in initialLinks where lhs != rhs {
            physicalLinks.insert(UndirectedLink(lhs, rhs))
        }
        refreshAllDirectPeers()
        runUntilQuiescent()
    }

    // MARK: - Inspection

    public var nodeIDs: [String] {
        orderedNodeIDs
    }

    public var pendingWireFrames: [SimulatedWireFrame] {
        wireQueue
    }

    public func node(_ nodeID: String) -> SimulatedNodeState? {
        nodesByID[nodeID]
    }

    public func hasPhysicalLink(_ nodeA: String, _ nodeB: String) -> Bool {
        physicalLinks.contains(UndirectedLink(nodeA, nodeB))
    }

    // MARK: - Topology & Strategy Mutations

    public mutating func addNode(
        nodeID: String,
        displayName: String,
        seed: String? = nil,
        routingStrategy: RoutingStrategy = .managedFlooding,
        initialSprayCopies: Int = 4
    ) {
        guard nodesByID[nodeID] == nil else { return }
        let sealer = SimulatedEnvelopeSealer(seed: seed ?? "seed-\(nodeID)")
        let identity = NodeIdentity(
            nodeID: nodeID,
            displayName: displayName,
            publicKeyBase64: sealer.publicKeyBase64
        )
        var router = MeshRouter(
            localIdentity: identity,
            routingStrategy: routingStrategy,
            initialSprayCopies: initialSprayCopies
        )
        // Share public key directory across existing simulated nodes so offline DTN E2EE works seamlessly
        for existingID in orderedNodeIDs {
            if let existing = nodesByID[existingID] {
                router.registerPeerIdentity(existing.identity)
                nodesByID[existingID]?.router.registerPeerIdentity(identity)
            }
        }
        nodesByID[nodeID] = SimulatedNodeState(router: router, sealer: sealer)
        orderedNodeIDs.append(nodeID)
    }

    public mutating func setRoutingStrategy(
        _ strategy: RoutingStrategy,
        initialSprayCopies: Int = 4
    ) {
        for id in orderedNodeIDs {
            nodesByID[id]?.router.routingStrategy = strategy
            nodesByID[id]?.router.initialSprayCopies = max(1, initialSprayCopies)
        }
    }

    public mutating func updateNodeDisplayName(
        _ displayName: String,
        for nodeID: String,
        settle: Bool = true
    ) {
        guard nodesByID[nodeID] != nil else { return }
        let effects = nodesByID[nodeID]!.router.updateLocalProfile(
            displayName: displayName,
            now: currentTime
        )
        if let updatedIdentity = nodesByID[nodeID]?.identity {
            for otherID in orderedNodeIDs where otherID != nodeID {
                nodesByID[otherID]?.router.registerPeerIdentity(updatedIdentity)
            }
        }
        processEffects(effects, on: nodeID)
        if settle {
            runUntilQuiescent()
        }
    }

    public mutating func resetTelemetry() {
        for id in orderedNodeIDs {
            nodesByID[id]?.router.resetTelemetry()
            nodesByID[id]?.packetLogs.removeAll()
        }
    }

    public mutating func addPhysicalLink(
        _ nodeA: String,
        _ nodeB: String,
        settle: Bool = true
    ) {
        guard nodeA != nodeB, nodesByID[nodeA] != nil, nodesByID[nodeB] != nil else { return }
        let inserted = physicalLinks.insert(UndirectedLink(nodeA, nodeB)).inserted
        guard inserted else { return }
        refreshDirectPeers(for: nodeA)
        refreshDirectPeers(for: nodeB)
        if settle {
            runUntilQuiescent()
        }
    }

    public mutating func removePhysicalLink(
        _ nodeA: String,
        _ nodeB: String,
        settle: Bool = true
    ) {
        let removed = physicalLinks.remove(UndirectedLink(nodeA, nodeB)) != nil
        guard removed else { return }
        // Drop any in-flight frames traversing the severed physical radio link
        wireQueue.removeAll { frame in
            UndirectedLink(frame.fromNodeID, frame.toNodeID) == UndirectedLink(nodeA, nodeB)
        }
        refreshDirectPeers(for: nodeA)
        refreshDirectPeers(for: nodeB)
        if settle {
            runUntilQuiescent()
        }
    }

    public mutating func setPeerBlocked(
        on ownerNodeID: String,
        blocking blockedPeerID: String,
        isBlocked: Bool,
        settle: Bool = true
    ) {
        guard nodesByID[ownerNodeID] != nil else { return }
        let effects = nodesByID[ownerNodeID]!.router.setPeerBlocked(
            blockedPeerID,
            isBlocked: isBlocked,
            now: currentTime
        )
        processEffects(effects, on: ownerNodeID)
        if settle {
            runUntilQuiescent()
        }
    }

    public mutating func setSymmetricBlock(
        _ nodeA: String,
        _ nodeB: String,
        isBlocked: Bool,
        settle: Bool = true
    ) {
        setPeerBlocked(on: nodeA, blocking: nodeB, isBlocked: isBlocked, settle: false)
        setPeerBlocked(on: nodeB, blocking: nodeA, isBlocked: isBlocked, settle: false)
        if settle {
            runUntilQuiescent()
        }
    }

    // MARK: - Messaging, SOS & Ping Actions

    @discardableResult
    public mutating func sendChat(
        from senderID: String,
        to targetID: String = MeshPacket.broadcastTarget,
        text: String,
        coordinate: GeoCoordinate? = nil,
        encryptE2EE: Bool? = nil,
        ttl: Int = 4,
        settle: Bool = true
    ) throws -> UUID {
        guard let senderState = nodesByID[senderID] else {
            preconditionFailure("Unknown simulated sender nodeID: \(senderID)")
        }

        let shouldEncrypt = encryptE2EE ?? (targetID != MeshPacket.broadcastTarget)
        let sealer: (any EnvelopeSealer)? = shouldEncrypt ? senderState.sealer : nil
        let recipientKey = nodesByID[targetID]?.identity.publicKeyBase64

        let (packetID, effects) = try nodesByID[senderID]!.router.sendChat(
            text: text,
            to: targetID,
            coordinate: coordinate,
            ttl: ttl,
            sealer: sealer,
            recipientPublicKeyBase64: recipientKey,
            now: currentTime
        )
        processEffects(effects, on: senderID)
        if settle {
            runUntilQuiescent()
        }
        return packetID
    }

    @discardableResult
    public mutating func sendSOS(
        from senderID: String,
        text: String,
        coordinate: GeoCoordinate? = nil,
        ttl: Int = 6,
        settle: Bool = true
    ) throws -> UUID {
        guard nodesByID[senderID] != nil else {
            preconditionFailure("Unknown simulated sender nodeID: \(senderID)")
        }
        let (packetID, effects) = try nodesByID[senderID]!.router.sendSOS(
            text: text,
            coordinate: coordinate,
            ttl: ttl,
            now: currentTime
        )
        processEffects(effects, on: senderID)
        if settle {
            runUntilQuiescent()
        }
        return packetID
    }

    @discardableResult
    public mutating func sendPing(
        from senderID: String,
        to targetID: String,
        ttl: Int = 4,
        settle: Bool = true
    ) throws -> UUID {
        guard nodesByID[senderID] != nil else {
            preconditionFailure("Unknown simulated sender nodeID: \(senderID)")
        }
        let (probeID, effects) = try nodesByID[senderID]!.router.sendPing(
            to: targetID,
            ttl: ttl,
            now: currentTime
        )
        processEffects(effects, on: senderID)
        if settle {
            runUntilQuiescent()
        }
        return probeID
    }

    /// Injects a raw wire frame directly across an existing physical link (e.g. to verify ingress filtering).
    public mutating func injectDirectFrame(
        rawData: Data,
        from senderID: String,
        to receiverID: String
    ) {
        guard nodesByID[receiverID] != nil else { return }
        let sealer = nodesByID[receiverID]?.sealer
        let effects = nodesByID[receiverID]!.router.handleIncoming(
            rawData: rawData,
            fromDirectPeerID: senderID,
            sealer: sealer,
            now: currentTime
        )
        processEffects(effects, on: receiverID)
    }

    // MARK: - Event Loop & Simulated Clock

    public mutating func advanceTime(by interval: TimeInterval) {
        guard interval > 0 else { return }
        currentTime = currentTime.addingTimeInterval(interval)
    }

    @discardableResult
    public mutating func step() -> Bool {
        guard !wireQueue.isEmpty else { return false }

        // Find the earliest frame without O(n) shifting on sorted tail if possible, or pick min index
        var bestIndex = 0
        for idx in 1..<wireQueue.count {
            let candidate = wireQueue[idx]
            let currentBest = wireQueue[bestIndex]
            if candidate.deliverAt < currentBest.deliverAt
                || (candidate.deliverAt == currentBest.deliverAt
                    && candidate.sequenceNumber < currentBest.sequenceNumber)
            {
                bestIndex = idx
            }
        }

        let frame = wireQueue.remove(at: bestIndex)
        if frame.deliverAt > currentTime {
            currentTime = frame.deliverAt
        }

        guard hasPhysicalLink(frame.fromNodeID, frame.toNodeID),
              let receiverSealer = nodesByID[frame.toNodeID]?.sealer
        else {
            return true
        }

        let effects = nodesByID[frame.toNodeID]!.router.handleIncoming(
            rawData: frame.data,
            fromDirectPeerID: frame.fromNodeID,
            sealer: receiverSealer,
            now: currentTime
        )
        processEffects(effects, on: frame.toNodeID)
        return true
    }

    @discardableResult
    public mutating func runUntilQuiescent(maxSteps: Int = 10_000) -> Int {
        var steps = 0
        while steps < maxSteps, step() {
            steps += 1
        }
        return steps
    }

    // MARK: - Internal Wiring

    private mutating func refreshAllDirectPeers() {
        for id in orderedNodeIDs {
            refreshDirectPeers(for: id)
        }
    }

    private mutating func refreshDirectPeers(for nodeID: String) {
        guard nodesByID[nodeID] != nil else { return }
        let neighbors: [NodeIdentity] = orderedNodeIDs.compactMap { otherID in
            guard otherID != nodeID,
                  hasPhysicalLink(nodeID, otherID),
                  let other = nodesByID[otherID]
            else {
                return nil
            }
            return other.identity
        }
        let effects = nodesByID[nodeID]!.router.updateDirectPeers(neighbors, now: currentTime)
        processEffects(effects, on: nodeID)
    }

    private mutating func processEffects(_ effects: [RouterEffect], on originNodeID: String) {
        for effect in effects {
            switch effect {
            case let .transmit(data, packet, toDirectPeerIDs):
                for targetPeerID in toDirectPeerIDs where hasPhysicalLink(originNodeID, targetPeerID) {
                    let seq = nextSequenceNumber
                    nextSequenceNumber &+= 1
                    wireQueue.append(
                        SimulatedWireFrame(
                            sequenceNumber: seq,
                            fromNodeID: originNodeID,
                            toNodeID: targetPeerID,
                            data: data,
                            packet: packet,
                            deliverAt: currentTime.addingTimeInterval(hopLatency)
                        )
                    )
                }

            case let .messageReceived(message):
                nodesByID[originNodeID]?.receivedMessages.append(message)
                maybeEnqueueFriendlyAutoReply(to: message, on: originNodeID)

            case let .deliveryUpdated(packetID, state, routeNames, rttMs):
                nodesByID[originNodeID]?.deliveryStates[packetID] = state
                nodesByID[originNodeID]?.deliveryRoutes[packetID] = routeNames
                if let rttMs {
                    nodesByID[originNodeID]?.deliveryRTTMs[packetID] = rttMs
                }

            case let .pingCompleted(peerID, rttMs, hops):
                nodesByID[originNodeID]?.completedPings.append(
                    CompletedPingRecord(peerID: peerID, rttMs: rttMs, hops: hops)
                )

            case let .packetLogged(entry):
                nodesByID[originNodeID]?.packetLogs.append(entry)
                if let logs = nodesByID[originNodeID]?.packetLogs, logs.count > 500 {
                    nodesByID[originNodeID]?.packetLogs = Array(logs.suffix(500))
                }
            }
        }
    }

    private mutating func maybeEnqueueFriendlyAutoReply(
        to message: ReceivedMeshMessage,
        on responderID: String
    ) {
        guard autoReplyEnabled,
              message.packetType == .chat,
              responderID == Self.nodeBID || responderID == Self.nodeCID,
              message.senderID == Self.nodeAID,
              !autoRepliedPacketIDs.contains(message.id)
        else {
            return
        }

        // For broadcast, only let iPhone-C (or iPhone-B if C isn't target) reply once per packetID
        if message.targetID == MeshPacket.broadcastTarget, responderID != Self.nodeCID {
            return
        }

        autoRepliedPacketIDs.insert(message.id)
        let responderName = nodesByID[responderID]?.identity.displayName ?? responderID
        let replyTarget =
            message.targetID == MeshPacket.broadcastTarget
            ? MeshPacket.broadcastTarget
            : message.senderID
        let replyText = "[\(responderName)] Đã nhận qua \(message.hopCount) bước nhảy: \"\(message.text)\""

        _ = try? sendChat(
            from: responderID,
            to: replyTarget,
            text: replyText,
            settle: false
        )
    }
}
