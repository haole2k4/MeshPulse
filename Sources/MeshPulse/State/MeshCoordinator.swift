#if canImport(SwiftUI)
import Foundation
import MeshCore
import Observation
import SwiftUI
import os

// MARK: - Platform Adapter Seams (Phase 3 & Phase 4 Ready)

public enum TransportEvent: Sendable, Equatable {
    case peersChanged([NodeIdentity])
    case dataReceived(Data, fromPeerID: String)
    case radioStateChanged(isRunning: Bool, statusNote: String?)
}

@MainActor
public protocol MeshTransportAdapter: AnyObject {
    var events: AsyncStream<TransportEvent> { get }
    func start(localIdentity: NodeIdentity)
    func stop()
    func updateLocalIdentity(_ identity: NodeIdentity)
    func send(_ data: Data, toPeerIDs peerIDs: [String])
}

@MainActor
public protocol OfflineLocationProviding: AnyObject {
    func currentCoordinate() async -> GeoCoordinate?
}

// MARK: - Navigation & Conversation Models

public enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case topology
    case broadcast
    case direct
    case lab

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .topology:
            "Mạng lưới"
        case .broadcast:
            "Kênh Chung"
        case .direct:
            "Cá nhân"
        case .lab:
            "Mesh Lab"
        }
    }

    public var systemImage: String {
        switch self {
        case .topology:
            "point.3.connected.trianglepath.dotted"
        case .broadcast:
            "antenna.radiowaves.left.and.right"
        case .direct:
            "lock.shield.fill"
        case .lab:
            "flask.fill"
        }
    }
}

public struct ChatThreadItem: Identifiable, Sendable, Equatable, Codable {
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

    public init(
        id: UUID,
        peerThreadID: String,
        senderID: String,
        senderName: String,
        targetID: String,
        text: String,
        coordinate: GeoCoordinate?,
        deliveryState: DeliveryState,
        routeNames: [String],
        hopCount: Int,
        remainingTTL: Int,
        rttMs: Int?,
        isEncrypted: Bool,
        isOutgoing: Bool,
        isSOS: Bool,
        timestamp: Date
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
    }
}

public struct ActivePacketPulse: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let fromNodeID: String
    public let toNodeID: String
    public let packetType: PacketType
    public let isDirectP2P: Bool
    public let startedAt: Date
    public let duration: TimeInterval

    public init(
        id: UUID = UUID(),
        fromNodeID: String,
        toNodeID: String,
        packetType: PacketType,
        isDirectP2P: Bool,
        startedAt: Date = Date(),
        duration: TimeInterval = 0.55
    ) {
        self.id = id
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.packetType = packetType
        self.isDirectP2P = isDirectP2P
        self.startedAt = startedAt
        self.duration = duration
    }
}

// MARK: - Central Application Coordinator

@Observable
@MainActor
public final class MeshCoordinator {
    private static let nodeIDDefaultsKey = "com.haole2k4.MeshPulse.localNodeID"
    private static let displayNameDefaultsKey = "com.haole2k4.MeshPulse.localDisplayName"
    private static let maxPacketLogEntries = 200

    // MARK: Navigation & UI State

    public var selectedTab: AppTab = .topology
    public var selectedDirectPeerID: String?
    public var activeSOSBanner: ChatThreadItem?

    public private(set) var isMockMode: Bool
    public private(set) var isRadioEnabled: Bool = true
    public private(set) var localDisplayName: String
    public let localNodeID: String
    public private(set) var radioStatusNote: String?

    public private(set) var directThreads: [String: [ChatThreadItem]] = [:]
    public private(set) var activePulses: [ActivePacketPulse] = []

    // MARK: Engines & Platform Adapters

    private let defaults: UserDefaults
    private var mockNetwork: SimulatedMeshNetwork
    private var mockBroadcastMessages: [ChatThreadItem] = []
    private var savedMockLinksBeforePause: [(String, String)] = []
    private var syncedMockIncomingIDs: Set<UUID> = []

    private var liveRouter: MeshRouter
    private var liveFallbackSealer: SimulatedEnvelopeSealer
    private var liveBroadcastMessages: [ChatThreadItem] = []
    private var livePacketLogs: [PacketLogEntry] = []
    private let dtnStore: DiskDTNStore?
    private var lastPersistedState: PersistedMeshState?
    private let persistenceLogger = Logger(subsystem: "com.haole2k4.MeshPulse", category: "DiskDTNStore")

    private var liveTransport: (any MeshTransportAdapter)?
    private var liveSealer: (any EnvelopeSealer)?
    private var locationProvider: (any OfflineLocationProviding)?
    private var transportStreamTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pulseCleanupTask: Task<Void, Never>?

    public init(
        startInMockMode: Bool = true,
        transport: (any MeshTransportAdapter)? = nil,
        sealer: (any EnvelopeSealer)? = nil,
        locationProvider: (any OfflineLocationProviding)? = nil,
        dtnStore: DiskDTNStore? = DiskDTNStore.defaultStore(),
        defaults: UserDefaults = .standard
    ) {
        let resolvedNodeID: String
        if let existing = defaults.string(forKey: Self.nodeIDDefaultsKey), !existing.isEmpty {
            resolvedNodeID = existing
        } else {
            let shortCode = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(4)).uppercased()
            let generated = "node-\(shortCode)"
            defaults.set(generated, forKey: Self.nodeIDDefaultsKey)
            resolvedNodeID = generated
        }

        let resolvedDisplayName: String
        if let existingName = defaults.string(forKey: Self.displayNameDefaultsKey), !existingName.isEmpty {
            resolvedDisplayName = existingName
        } else {
            let suffix = String(resolvedNodeID.suffix(4))
            let defaultName = "iPhone-\(suffix)"
            defaults.set(defaultName, forKey: Self.displayNameDefaultsKey)
            resolvedDisplayName = defaultName
        }

        self.defaults = defaults
        self.localNodeID = resolvedNodeID
        self.localDisplayName = resolvedDisplayName
        self.isMockMode = startInMockMode
        self.liveTransport = transport
        self.liveSealer = sealer
        self.locationProvider = locationProvider
        self.dtnStore = dtnStore

        let fallbackSealer = SimulatedEnvelopeSealer(seed: resolvedNodeID)
        self.liveFallbackSealer = fallbackSealer

        let effectiveLivePubKey = sealer?.publicKeyBase64 ?? fallbackSealer.publicKeyBase64
        let liveIdentity = NodeIdentity(
            nodeID: resolvedNodeID,
            displayName: resolvedDisplayName,
            publicKeyBase64: effectiveLivePubKey
        )
        var initialLiveRouter = MeshRouter(localIdentity: liveIdentity)
        if let dtnStore {
            let persisted = dtnStore.load()
            initialLiveRouter.restorePersistedState(persisted)
        }
        self.liveRouter = initialLiveRouter
        self.lastPersistedState = initialLiveRouter.snapshotPersistedState()
        self.mockNetwork = SimulatedMeshNetwork(
            nodeSpecs: [
                (SimulatedMeshNetwork.nodeAID, resolvedDisplayName, "seed-iphone-a"),
                (SimulatedMeshNetwork.nodeBID, "iPhone-B", "seed-iphone-b"),
                (SimulatedMeshNetwork.nodeCID, "iPhone-C", "seed-iphone-c"),
            ],
            initialLinks: [
                (SimulatedMeshNetwork.nodeAID, SimulatedMeshNetwork.nodeBID),
                (SimulatedMeshNetwork.nodeBID, SimulatedMeshNetwork.nodeCID),
                (SimulatedMeshNetwork.nodeAID, SimulatedMeshNetwork.nodeCID),
            ],
            autoReplyEnabled: true,
            startTime: Date()
        )

        bootstrapMockScenario()
        if !startInMockMode {
            activateLiveTransportIfAvailable()
        }
    }

    // MARK: - Live Service Injection Hook (Phase 3 & Phase 4)

    public func attachLiveServices(
        transport: (any MeshTransportAdapter)? = nil,
        sealer: (any EnvelopeSealer)? = nil,
        locationProvider: (any OfflineLocationProviding)? = nil
    ) {
        if let transport {
            stopLiveRuntime(stopAdapter: true)
            self.liveTransport = transport
        }
        if let sealer {
            self.liveSealer = sealer
            let effects = liveRouter.updateLocalProfile(publicKeyBase64: sealer.publicKeyBase64)
            if !isMockMode {
                liveTransport?.updateLocalIdentity(liveRouter.localIdentity)
                processLiveEffects(effects)
            }
        }
        if let locationProvider {
            self.locationProvider = locationProvider
        }
        if !isMockMode, isRadioEnabled {
            activateLiveTransportIfAvailable()
        }
    }

    public func handleScenePhase(_ phase: ScenePhase) {
        if phase != .active {
            persistLiveMeshStateIfNeeded()
            return
        }
        guard !isMockMode, isRadioEnabled else { return }
        activateLiveTransportIfAvailable()
        let effects = liveRouter.broadcastHeartbeat()
        processLiveEffects(effects)
    }

    // MARK: - Computed Read Models for 4 Tabs

    public var localIdentity: NodeIdentity {
        if isMockMode, let mockLocal = mockNetwork.node(SimulatedMeshNetwork.nodeAID)?.identity {
            return mockLocal
        }
        return liveRouter.localIdentity
    }

    public var routingStrategy: RoutingStrategy {
        isMockMode
            ? (mockNetwork.node(SimulatedMeshNetwork.nodeAID)?.router.routingStrategy ?? .managedFlooding)
            : liveRouter.routingStrategy
    }

    public var peers: [PeerSummary] {
        let raw = isMockMode
            ? (mockNetwork.node(SimulatedMeshNetwork.nodeAID)?.router.knownPeers ?? [])
            : liveRouter.knownPeers
        guard isRadioEnabled else {
            return raw.map { summary in
                PeerSummary(
                    identity: summary.identity,
                    linkKind: .offlineDTN,
                    lastRTTMilliseconds: summary.lastRTTMilliseconds,
                    lastSeen: summary.lastSeen
                )
            }
        }
        return raw
    }

    public var blockedPeerIDs: Set<String> {
        if isMockMode {
            return mockNetwork.node(SimulatedMeshNetwork.nodeAID)?.router.blockedPeerIDs ?? []
        }
        return liveRouter.blockedPeerIDs
    }

    /// Deterministic union of known peers, blocked peers, and (in Mock Mode) simulated stations
    /// so toggling Topology Blocker in Mesh Lab never hides or reorders rows under the user's finger.
    public var controllableLabPeers: [PeerSummary] {
        var byID: [String: PeerSummary] = [:]
        for summary in peers {
            byID[summary.id] = summary
        }
        if isMockMode {
            for mockID in [SimulatedMeshNetwork.nodeBID, SimulatedMeshNetwork.nodeCID] where byID[mockID] == nil {
                if let identity = mockNetwork.node(mockID)?.identity {
                    byID[mockID] = PeerSummary(identity: identity, linkKind: .offlineDTN, lastSeen: .distantPast)
                }
            }
        }
        for blockedID in blockedPeerIDs where byID[blockedID] == nil && blockedID != localIdentity.nodeID {
            byID[blockedID] = PeerSummary(
                identity: NodeIdentity(nodeID: blockedID, displayName: blockedID),
                linkKind: .offlineDTN,
                lastSeen: .distantPast
            )
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.identity.displayName != rhs.identity.displayName {
                return lhs.identity.displayName < rhs.identity.displayName
            }
            return lhs.id < rhs.id
        }
    }

    /// Merged list of peers and existing 1-to-1 threads so offline stations remain reachable via DTN Outbox.
    public var directConversationPeers: [PeerSummary] {
        let mockPeerIDs: Set<String> = [
            SimulatedMeshNetwork.nodeAID,
            SimulatedMeshNetwork.nodeBID,
            SimulatedMeshNetwork.nodeCID,
        ]
        var byID: [String: PeerSummary] = [:]
        for summary in peers {
            byID[summary.id] = summary
        }
        for (peerID, items) in directThreads where byID[peerID] == nil {
            let isMockThread = mockPeerIDs.contains(peerID)
            guard isMockThread == isMockMode else { continue }
            let resolvedName =
                items.last(where: { !$0.isOutgoing })?.senderName
                ?? peerID
            byID[peerID] = PeerSummary(
                identity: NodeIdentity(nodeID: peerID, displayName: resolvedName),
                linkKind: .offlineDTN,
                lastSeen: items.last?.timestamp ?? .distantPast
            )
        }
        return byID.values.sorted { lhs, rhs in
            let lhsLatest = directThreads[lhs.id]?.last?.timestamp ?? .distantPast
            let rhsLatest = directThreads[rhs.id]?.last?.timestamp ?? .distantPast
            if lhsLatest != rhsLatest {
                return lhsLatest > rhsLatest
            }
            if lhs.identity.displayName != rhs.identity.displayName {
                return lhs.identity.displayName < rhs.identity.displayName
            }
            return lhs.id < rhs.id
        }
    }

    public func peerSummary(for peerID: String) -> PeerSummary {
        if let match = peers.first(where: { $0.id == peerID }) {
            return match
        }
        if isMockMode, let mockIdentity = mockNetwork.node(peerID)?.identity {
            return PeerSummary(identity: mockIdentity, linkKind: .offlineDTN, lastSeen: .distantPast)
        }
        let fallbackName =
            directThreads[peerID]?.last(where: { !$0.isOutgoing })?.senderName
            ?? peerID
        return PeerSummary(
            identity: NodeIdentity(nodeID: peerID, displayName: fallbackName),
            linkKind: .offlineDTN,
            lastSeen: directThreads[peerID]?.last?.timestamp ?? .distantPast
        )
    }

    public var directP2PCount: Int {
        guard isRadioEnabled else { return 0 }
        return peers.reduce(into: 0) { count, peer in
            if case .directP2P = peer.linkKind {
                count += 1
            }
        }
    }

    public var meshRelayedCount: Int {
        guard isRadioEnabled else { return 0 }
        return peers.reduce(into: 0) { count, peer in
            if case .relayedMesh = peer.linkKind {
                count += 1
            }
        }
    }

    public var topologyEdges: [TopologyEdge] {
        guard isRadioEnabled else { return [] }
        if isMockMode {
            return mockNetwork.node(SimulatedMeshNetwork.nodeAID)?.router.topologyEdges ?? []
        }
        return liveRouter.topologyEdges
    }

    public var dtnRecords: [StoredDTNRecord] {
        let now = isMockMode ? mockNetwork.currentTime : Date()
        if isMockMode {
            return mockNetwork.node(SimulatedMeshNetwork.nodeAID)?.router.dtnOutbox.allRecords(now: now) ?? []
        }
        return liveRouter.dtnOutbox.allRecords(now: now)
    }

    public var telemetry: TelemetrySnapshot {
        if isMockMode {
            return mockNetwork.node(SimulatedMeshNetwork.nodeAID)?.router.telemetry ?? TelemetrySnapshot()
        }
        return liveRouter.telemetry
    }

    public var packetLogs: [PacketLogEntry] {
        if isMockMode {
            let logs = mockNetwork.node(SimulatedMeshNetwork.nodeAID)?.packetLogs ?? []
            return Array(logs.suffix(Self.maxPacketLogEntries).reversed())
        }
        return Array(livePacketLogs.suffix(Self.maxPacketLogEntries).reversed())
    }

    public var broadcastMessages: [ChatThreadItem] {
        isMockMode ? mockBroadcastMessages : liveBroadcastMessages
    }

    public func messages(forPeerID peerID: String) -> [ChatThreadItem] {
        directThreads[peerID] ?? []
    }

    public func openDirectConversation(with peerID: String) {
        selectedDirectPeerID = peerID
        selectedTab = .direct
    }

    public func dismissSOSBanner() {
        activeSOSBanner = nil
    }

    // MARK: - Mode, Radio & Profile Actions

    public func toggleRadio() {
        isRadioEnabled.toggle()
        if isMockMode {
            let localID = SimulatedMeshNetwork.nodeAID
            if !isRadioEnabled {
                savedMockLinksBeforePause = mockNetwork.nodeIDs.compactMap { otherID in
                    guard otherID != localID, mockNetwork.hasPhysicalLink(localID, otherID) else {
                        return nil
                    }
                    return (localID, otherID)
                }
                for (lhs, rhs) in savedMockLinksBeforePause {
                    mockNetwork.removePhysicalLink(lhs, rhs, settle: false)
                }
                runMockStepsAndCapturePulses()
            } else {
                let linksToRestore =
                    savedMockLinksBeforePause.isEmpty
                    ? [(localID, SimulatedMeshNetwork.nodeBID), (localID, SimulatedMeshNetwork.nodeCID)]
                    : savedMockLinksBeforePause
                for (lhs, rhs) in linksToRestore {
                    mockNetwork.addPhysicalLink(lhs, rhs, settle: false)
                }
                savedMockLinksBeforePause.removeAll()
                runMockStepsAndCapturePulses()
            }
        } else {
            if isRadioEnabled {
                activateLiveTransportIfAvailable()
            } else {
                stopLiveRuntime(stopAdapter: true)
                radioStatusNote = "Đã tạm tắt sóng ngoại tuyến"
                let effects = liveRouter.updateDirectPeers([])
                processLiveEffects(effects)
            }
        }
    }

    public func setMockMode(_ enabled: Bool) {
        guard isMockMode != enabled else { return }
        isMockMode = enabled
        activePulses.removeAll()
        activeSOSBanner = nil
        selectedDirectPeerID = nil

        if enabled {
            stopLiveRuntime(stopAdapter: true)
        } else {
            if isRadioEnabled {
                activateLiveTransportIfAvailable()
            } else {
                stopLiveRuntime(stopAdapter: true)
                radioStatusNote = "Đã tạm tắt sóng ngoại tuyến"
            }
        }
    }

    public func updateDisplayName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        localDisplayName = trimmed
        defaults.set(trimmed, forKey: Self.displayNameDefaultsKey)

        mockNetwork.updateNodeDisplayName(
            trimmed,
            for: SimulatedMeshNetwork.nodeAID,
            settle: isMockMode
        )

        let liveEffects = liveRouter.updateLocalProfile(displayName: trimmed)
        if !isMockMode {
            liveTransport?.updateLocalIdentity(liveRouter.localIdentity)
            processLiveEffects(liveEffects)
        }
    }

    public func setRoutingStrategy(_ strategy: RoutingStrategy) {
        if isMockMode {
            mockNetwork.setRoutingStrategy(strategy)
        } else {
            liveRouter.routingStrategy = strategy
        }
    }

    public func resetTelemetry() {
        if isMockMode {
            mockNetwork.resetTelemetry()
        } else {
            liveRouter.resetTelemetry()
            livePacketLogs.removeAll()
            persistLiveMeshStateIfNeeded()
        }
    }

    // MARK: - Topology Blocker & Mock Link Controls

    public func isPeerBlocked(_ peerID: String) -> Bool {
        if isMockMode {
            return mockNetwork.node(SimulatedMeshNetwork.nodeAID)?.router.blockedPeerIDs.contains(peerID) ?? false
        }
        return liveRouter.blockedPeerIDs.contains(peerID)
    }

    public func setPeerBlocked(_ peerID: String, isBlocked: Bool) {
        if isMockMode {
            mockNetwork.setSymmetricBlock(
                SimulatedMeshNetwork.nodeAID,
                peerID,
                isBlocked: isBlocked,
                settle: false
            )
            runMockStepsAndCapturePulses()
        } else {
            let effects = liveRouter.setPeerBlocked(peerID, isBlocked: isBlocked)
            processLiveEffects(effects)
        }
    }

    public func hasPhysicalLinkInMock(_ peerA: String, _ peerB: String) -> Bool {
        mockNetwork.hasPhysicalLink(peerA, peerB)
    }

    public func setPhysicalLinkInMock(_ peerA: String, _ peerB: String, isConnected: Bool) {
        guard isMockMode else { return }
        if isConnected {
            mockNetwork.addPhysicalLink(peerA, peerB, settle: false)
        } else {
            mockNetwork.removePhysicalLink(peerA, peerB, settle: false)
        }
        runMockStepsAndCapturePulses()
    }

    // MARK: - Messaging, SOS & Ping Operations

    public func sendBroadcast(text: String, includeLocation: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task { @MainActor in
            let coord = includeLocation ? await resolveCoordinate() : nil
            dispatchBroadcastNow(text: trimmed, coordinate: coord)
        }
    }

    public func sendDirectMessage(to peerID: String, text: String, includeLocation: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task { @MainActor in
            let coord = includeLocation ? await resolveCoordinate() : nil
            dispatchDirectMessageNow(to: peerID, text: trimmed, coordinate: coord)
        }
    }

    public func triggerSOS(customNote: String? = nil) {
        let note =
            customNote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? customNote!
            : "KHẨN CẤP SOS: Cần hỗ trợ tại vị trí GPS ngoại tuyến này!"

        Task { @MainActor in
            let coord = await resolveCoordinate()
            dispatchSOSNow(text: note, coordinate: coord)
        }
    }

    public func ping(peerID: String) {
        if isMockMode {
            _ = try? mockNetwork.sendPing(
                from: SimulatedMeshNetwork.nodeAID,
                to: peerID,
                settle: false
            )
            runMockStepsAndCapturePulses()
        } else {
            if let (_, effects) = try? liveRouter.sendPing(to: peerID) {
                processLiveEffects(effects)
            }
        }
    }

    // MARK: - Internal Dispatch & State Synchronization

    private func dispatchBroadcastNow(text: String, coordinate: GeoCoordinate?) {
        let now = Date()
        if isMockMode {
            mockNetwork.advanceTime(by: max(0.005, now.timeIntervalSince(mockNetwork.currentTime)))
            guard let msgID = try? mockNetwork.sendChat(
                from: SimulatedMeshNetwork.nodeAID,
                to: MeshPacket.broadcastTarget,
                text: text,
                coordinate: coordinate,
                settle: false
            ) else {
                return
            }

            let outgoing = ChatThreadItem(
                id: msgID,
                peerThreadID: MeshPacket.broadcastTarget,
                senderID: SimulatedMeshNetwork.nodeAID,
                senderName: localDisplayName,
                targetID: MeshPacket.broadcastTarget,
                text: text,
                coordinate: coordinate,
                deliveryState: isRadioEnabled ? .sentDirect : .queuedDTN,
                routeNames: [localDisplayName],
                hopCount: 1,
                remainingTTL: 4,
                rttMs: nil,
                isEncrypted: false,
                isOutgoing: true,
                isSOS: false,
                timestamp: now
            )
            mockBroadcastMessages.append(outgoing)
            runMockStepsAndCapturePulses()
        } else {
            guard let (msgID, effects) = try? liveRouter.sendChat(
                text: text,
                to: MeshPacket.broadcastTarget,
                coordinate: coordinate,
                now: now
            ) else {
                return
            }
            let outgoing = ChatThreadItem(
                id: msgID,
                peerThreadID: MeshPacket.broadcastTarget,
                senderID: liveRouter.localIdentity.nodeID,
                senderName: liveRouter.localIdentity.displayName,
                targetID: MeshPacket.broadcastTarget,
                text: text,
                coordinate: coordinate,
                deliveryState: directP2PCount > 0 ? .sentDirect : .queuedDTN,
                routeNames: [liveRouter.localIdentity.displayName],
                hopCount: 1,
                remainingTTL: 4,
                rttMs: nil,
                isEncrypted: false,
                isOutgoing: true,
                isSOS: false,
                timestamp: now
            )
            liveBroadcastMessages.append(outgoing)
            processLiveEffects(effects)
        }
    }

    private func dispatchDirectMessageNow(to peerID: String, text: String, coordinate: GeoCoordinate?) {
        let now = Date()
        if isMockMode {
            mockNetwork.advanceTime(by: max(0.005, now.timeIntervalSince(mockNetwork.currentTime)))
            guard let msgID = try? mockNetwork.sendChat(
                from: SimulatedMeshNetwork.nodeAID,
                to: peerID,
                text: text,
                coordinate: coordinate,
                settle: false
            ) else {
                return
            }

            let initialState =
                mockNetwork.node(SimulatedMeshNetwork.nodeAID)?.deliveryStates[msgID] ?? .queuedDTN
            let initialRoute =
                mockNetwork.node(SimulatedMeshNetwork.nodeAID)?.deliveryRoutes[msgID] ?? [localDisplayName]

            let outgoing = ChatThreadItem(
                id: msgID,
                peerThreadID: peerID,
                senderID: SimulatedMeshNetwork.nodeAID,
                senderName: localDisplayName,
                targetID: peerID,
                text: text,
                coordinate: coordinate,
                deliveryState: initialState,
                routeNames: initialRoute,
                hopCount: max(1, initialRoute.count - 1),
                remainingTTL: 4,
                rttMs: nil,
                isEncrypted: true,
                isOutgoing: true,
                isSOS: false,
                timestamp: now
            )
            directThreads[peerID, default: []].append(outgoing)
            runMockStepsAndCapturePulses()
        } else {
            let activeSealer: any EnvelopeSealer = liveSealer ?? liveFallbackSealer
            let hasPeerPublicKey =
                liveRouter.knownPeers.first { $0.id == peerID }?.identity.publicKeyBase64 != nil

            guard let (msgID, effects) = try? liveRouter.sendChat(
                text: text,
                to: peerID,
                coordinate: coordinate,
                sealer: hasPeerPublicKey ? activeSealer : nil,
                now: now
            ) else {
                return
            }

            let outgoing = ChatThreadItem(
                id: msgID,
                peerThreadID: peerID,
                senderID: liveRouter.localIdentity.nodeID,
                senderName: liveRouter.localIdentity.displayName,
                targetID: peerID,
                text: text,
                coordinate: coordinate,
                deliveryState: .queuedDTN,
                routeNames: [liveRouter.localIdentity.displayName],
                hopCount: 1,
                remainingTTL: 4,
                rttMs: nil,
                isEncrypted: hasPeerPublicKey,
                isOutgoing: true,
                isSOS: false,
                timestamp: now
            )
            directThreads[peerID, default: []].append(outgoing)
            processLiveEffects(effects)
        }
    }

    private func dispatchSOSNow(text: String, coordinate: GeoCoordinate?) {
        let now = Date()
        if isMockMode {
            mockNetwork.advanceTime(by: max(0.005, now.timeIntervalSince(mockNetwork.currentTime)))
            guard let sosID = try? mockNetwork.sendSOS(
                from: SimulatedMeshNetwork.nodeAID,
                text: text,
                coordinate: coordinate,
                ttl: 6,
                settle: false
            ) else {
                return
            }
            let item = ChatThreadItem(
                id: sosID,
                peerThreadID: MeshPacket.broadcastTarget,
                senderID: SimulatedMeshNetwork.nodeAID,
                senderName: localDisplayName,
                targetID: MeshPacket.broadcastTarget,
                text: text,
                coordinate: coordinate,
                deliveryState: isRadioEnabled ? .sentDirect : .queuedDTN,
                routeNames: [localDisplayName],
                hopCount: 1,
                remainingTTL: 6,
                rttMs: nil,
                isEncrypted: false,
                isOutgoing: true,
                isSOS: true,
                timestamp: now
            )
            mockBroadcastMessages.append(item)
            activeSOSBanner = item
            runMockStepsAndCapturePulses()
        } else {
            guard let (sosID, effects) = try? liveRouter.sendSOS(
                text: text,
                coordinate: coordinate,
                ttl: 6,
                now: now
            ) else {
                return
            }
            let item = ChatThreadItem(
                id: sosID,
                peerThreadID: MeshPacket.broadcastTarget,
                senderID: liveRouter.localIdentity.nodeID,
                senderName: liveRouter.localIdentity.displayName,
                targetID: MeshPacket.broadcastTarget,
                text: text,
                coordinate: coordinate,
                deliveryState: directP2PCount > 0 ? .sentDirect : .queuedDTN,
                routeNames: [liveRouter.localIdentity.displayName],
                hopCount: 1,
                remainingTTL: 6,
                rttMs: nil,
                isEncrypted: false,
                isOutgoing: true,
                isSOS: true,
                timestamp: now
            )
            liveBroadcastMessages.append(item)
            activeSOSBanner = item
            processLiveEffects(effects)
        }
    }

    // MARK: - Mock Scenario Bootstrap & Pulse Choreographer

    private func bootstrapMockScenario() {
        selectedDirectPeerID = nil

        // Pre-block direct A <-> C link so user immediately sees 1-Hop P2P (iPhone-B) + 2-Hop Mesh (iPhone-C via B)
        mockNetwork.setSymmetricBlock(
            SimulatedMeshNetwork.nodeAID,
            SimulatedMeshNetwork.nodeCID,
            isBlocked: true,
            settle: true
        )

        // Seed 1 incoming 1-Hop broadcast from iPhone-B
        _ = try? mockNetwork.sendChat(
            from: SimulatedMeshNetwork.nodeBID,
            to: MeshPacket.broadcastTarget,
            text: "Trạm trung chuyển iPhone-B đang trực tuyến (1-Hop AWDL).",
            settle: true
        )

        // Seed 1 multi-hop E2EE 1-to-1 message from A -> B -> C (with auto-reply back C -> B -> A)
        if let seedID = try? mockNetwork.sendChat(
            from: SimulatedMeshNetwork.nodeAID,
            to: SimulatedMeshNetwork.nodeCID,
            text: "Kiểm tra đường truyền mã hóa bắc cầu qua iPhone-B.",
            settle: false
        ) {
            let seededOutgoing = ChatThreadItem(
                id: seedID,
                peerThreadID: SimulatedMeshNetwork.nodeCID,
                senderID: SimulatedMeshNetwork.nodeAID,
                senderName: localDisplayName,
                targetID: SimulatedMeshNetwork.nodeCID,
                text: "Kiểm tra đường truyền mã hóa bắc cầu qua iPhone-B.",
                coordinate: nil,
                deliveryState: .relayed,
                routeNames: [localDisplayName, "iPhone-B", "iPhone-C"],
                hopCount: 2,
                remainingTTL: 4,
                rttMs: nil,
                isEncrypted: true,
                isOutgoing: true,
                isSOS: false,
                timestamp: Date()
            )
            directThreads[SimulatedMeshNetwork.nodeCID, default: []].append(seededOutgoing)
        }

        mockNetwork.runUntilQuiescent()
        syncFromMockNodeState()
    }

    private func runMockStepsAndCapturePulses() {
        let baseStart = Date()
        var hopIndex = 0
        var generatedPulses: [ActivePacketPulse] = []

        var safetyCounter = 0
        while safetyCounter < 2_000, let nextFrame = earliestPendingMockFrame() {
            safetyCounter += 1
            if mockNetwork.hasPhysicalLink(nextFrame.fromNodeID, nextFrame.toNodeID),
               nextFrame.packet.type != .heartbeat
            {
                let involvesLocal =
                    nextFrame.fromNodeID == SimulatedMeshNetwork.nodeAID
                    || nextFrame.toNodeID == SimulatedMeshNetwork.nodeAID
                let isDirect =
                    involvesLocal
                    && !(mockNetwork.node(SimulatedMeshNetwork.nodeAID)?.router.blockedPeerIDs.contains(
                        nextFrame.fromNodeID == SimulatedMeshNetwork.nodeAID ? nextFrame.toNodeID : nextFrame.fromNodeID
                    ) ?? false)

                generatedPulses.append(
                    ActivePacketPulse(
                        fromNodeID: nextFrame.fromNodeID,
                        toNodeID: nextFrame.toNodeID,
                        packetType: nextFrame.packet.type,
                        isDirectP2P: isDirect,
                        startedAt: baseStart.addingTimeInterval(Double(hopIndex) * 0.16),
                        duration: 0.52
                    )
                )
                hopIndex += 1
            }
            _ = mockNetwork.step()
        }

        syncFromMockNodeState()
        appendPulses(generatedPulses)
    }

    private func earliestPendingMockFrame() -> SimulatedWireFrame? {
        mockNetwork.pendingWireFrames.min { lhs, rhs in
            if lhs.deliverAt != rhs.deliverAt {
                return lhs.deliverAt < rhs.deliverAt
            }
            return lhs.sequenceNumber < rhs.sequenceNumber
        }
    }

    private func syncFromMockNodeState() {
        guard let nodeA = mockNetwork.node(SimulatedMeshNetwork.nodeAID) else { return }

        // 1. Ingest newly arrived messages on iPhone-A
        for msg in nodeA.receivedMessages where !syncedMockIncomingIDs.contains(msg.id) {
            syncedMockIncomingIDs.insert(msg.id)
            let isBroadcast = (msg.targetID == MeshPacket.broadcastTarget || msg.packetType == .sos)
            let threadKey = isBroadcast ? MeshPacket.broadcastTarget : msg.senderID
            let item = ChatThreadItem(
                id: msg.id,
                peerThreadID: threadKey,
                senderID: msg.senderID,
                senderName: msg.senderName,
                targetID: msg.targetID,
                text: msg.text,
                coordinate: msg.coordinate,
                deliveryState: .deliveredAck,
                routeNames: msg.routeNames,
                hopCount: msg.hopCount,
                remainingTTL: msg.remainingTTL,
                rttMs: nil,
                isEncrypted: msg.isEncrypted,
                isOutgoing: false,
                isSOS: msg.packetType == .sos,
                timestamp: msg.timestamp
            )
            if isBroadcast {
                mockBroadcastMessages.append(item)
                if item.isSOS, isMockMode {
                    activeSOSBanner = item
                }
            } else {
                directThreads[threadKey, default: []].append(item)
            }
        }

        // 2. Refresh outgoing broadcast & 1-to-1 delivery states
        for idx in mockBroadcastMessages.indices where mockBroadcastMessages[idx].isOutgoing && mockBroadcastMessages[idx].deliveryState == .queuedDTN {
            let id = mockBroadcastMessages[idx].id
            let record = nodeA.router.dtnOutbox.record(for: id, now: mockNetwork.currentTime)
            if record == nil || record?.forwardedPeers.isEmpty == false {
                mockBroadcastMessages[idx].deliveryState = .sentDirect
            }
        }

        for peerID in Array(directThreads.keys) {
            guard var items = directThreads[peerID] else { continue }
            var changed = false
            for idx in items.indices where items[idx].isOutgoing {
                let id = items[idx].id
                if let updatedState = nodeA.deliveryStates[id], items[idx].deliveryState != updatedState {
                    items[idx].deliveryState = updatedState
                    changed = true
                }
                if let route = nodeA.deliveryRoutes[id], !route.isEmpty {
                    let normalized =
                        items[idx].deliveryState == .deliveredAck
                        ? Array(route.reversed())
                        : route
                    if items[idx].routeNames != normalized {
                        items[idx].routeNames = normalized
                        items[idx].hopCount = max(1, normalized.count - 1)
                        changed = true
                    }
                }
                if let rtt = nodeA.deliveryRTTMs[id], items[idx].rttMs != rtt {
                    items[idx].rttMs = rtt
                    changed = true
                }
            }
            if changed {
                directThreads[peerID] = items
            }
        }
    }

    // MARK: - Live Radio Event Loop

    private func activateLiveTransportIfAvailable() {
        guard let liveTransport else {
            radioStatusNote = "Chưa gắn MultipeerTransport"
            return
        }

        if transportStreamTask == nil {
            let stream = liveTransport.events
            transportStreamTask = Task { @MainActor [weak self] in
                for await event in stream {
                    guard let self, !self.isMockMode else { break }
                    self.handleLiveTransportEvent(event)
                }
                if !Task.isCancelled {
                    self?.transportStreamTask = nil
                }
            }
        }

        liveTransport.start(localIdentity: liveRouter.localIdentity)
        startLiveHeartbeatLoopIfNeeded()
    }

    private func startLiveHeartbeatLoopIfNeeded() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled, !self.isMockMode, self.isRadioEnabled else {
                    break
                }
                let effects = self.liveRouter.broadcastHeartbeat()
                self.processLiveEffects(effects)
            }
        }
    }

    private func stopLiveRuntime(stopAdapter: Bool) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        transportStreamTask?.cancel()
        transportStreamTask = nil
        if stopAdapter {
            liveTransport?.stop()
        }
    }

    private func handleLiveTransportEvent(_ event: TransportEvent) {
        switch event {
        case let .peersChanged(connectedPeers):
            let effects = liveRouter.updateDirectPeers(connectedPeers)
            processLiveEffects(effects)

        case let .dataReceived(data, peerID):
            let activeSealer: any EnvelopeSealer = liveSealer ?? liveFallbackSealer
            let effects = liveRouter.handleIncoming(
                rawData: data,
                fromDirectPeerID: peerID,
                sealer: activeSealer
            )
            processLiveEffects(effects)

        case let .radioStateChanged(running, note):
            isRadioEnabled = running
            radioStatusNote = note
        }
    }

    private func processLiveEffects(_ effects: [RouterEffect]) {
        let now = Date()
        var newPulses: [ActivePacketPulse] = []

        for effect in effects {
            switch effect {
            case let .transmit(data, packet, toDirectPeerIDs):
                liveTransport?.send(data, toPeerIDs: toDirectPeerIDs)
                if !toDirectPeerIDs.isEmpty,
                   let idx = liveBroadcastMessages.firstIndex(where: { $0.id == packet.id && $0.isOutgoing && $0.deliveryState == .queuedDTN })
                {
                    liveBroadcastMessages[idx].deliveryState = .sentDirect
                }
                if packet.type != .heartbeat {
                    for peerID in toDirectPeerIDs {
                        newPulses.append(
                            ActivePacketPulse(
                                fromNodeID: liveRouter.localIdentity.nodeID,
                                toNodeID: peerID,
                                packetType: packet.type,
                                isDirectP2P: liveRouter.activeDirectPeerIDs.contains(peerID),
                                startedAt: now
                            )
                        )
                    }
                }

            case let .messageReceived(msg):
                let isBroadcast = (msg.targetID == MeshPacket.broadcastTarget || msg.packetType == .sos)
                let threadKey = isBroadcast ? MeshPacket.broadcastTarget : msg.senderID
                let item = ChatThreadItem(
                    id: msg.id,
                    peerThreadID: threadKey,
                    senderID: msg.senderID,
                    senderName: msg.senderName,
                    targetID: msg.targetID,
                    text: msg.text,
                    coordinate: msg.coordinate,
                    deliveryState: .deliveredAck,
                    routeNames: msg.routeNames,
                    hopCount: msg.hopCount,
                    remainingTTL: msg.remainingTTL,
                    rttMs: nil,
                    isEncrypted: msg.isEncrypted,
                    isOutgoing: false,
                    isSOS: msg.packetType == .sos,
                    timestamp: msg.timestamp
                )
                if isBroadcast {
                    liveBroadcastMessages.append(item)
                    if item.isSOS, !isMockMode {
                        activeSOSBanner = item
                    }
                } else {
                    directThreads[threadKey, default: []].append(item)
                }

            case let .deliveryUpdated(packetID, state, routeNames, rttMs):
                for peerID in Array(directThreads.keys) {
                    guard var items = directThreads[peerID],
                          let idx = items.firstIndex(where: { $0.id == packetID })
                    else { continue }
                    items[idx].deliveryState = state
                    if !routeNames.isEmpty {
                        let normalized = (state == .deliveredAck) ? Array(routeNames.reversed()) : routeNames
                        items[idx].routeNames = normalized
                        items[idx].hopCount = max(1, normalized.count - 1)
                    }
                    if let rttMs {
                        items[idx].rttMs = rttMs
                    }
                    directThreads[peerID] = items
                }

            case .pingCompleted:
                break

            case let .packetLogged(entry):
                livePacketLogs.append(entry)
                if livePacketLogs.count > Self.maxPacketLogEntries * 2 {
                    livePacketLogs = Array(livePacketLogs.suffix(Self.maxPacketLogEntries))
                }
            }
        }

        appendPulses(newPulses)
        persistLiveMeshStateIfNeeded()
    }

    private func persistLiveMeshStateIfNeeded() {
        guard let dtnStore else { return }
        let snapshot = liveRouter.snapshotPersistedState()
        guard snapshot != lastPersistedState else { return }
        do {
            try dtnStore.save(snapshot)
            lastPersistedState = snapshot
        } catch {
            persistenceLogger.warning("Failed to save live mesh state: \(error.localizedDescription)")
        }
    }

    private func appendPulses(_ pulses: [ActivePacketPulse]) {
        guard !pulses.isEmpty else { return }
        let now = Date()
        activePulses.removeAll { now.timeIntervalSince($0.startedAt) > $0.duration + 0.1 }
        activePulses.append(contentsOf: pulses)
        if activePulses.count > 40 {
            activePulses = Array(activePulses.suffix(40))
        }

        pulseCleanupTask?.cancel()
        let latestEnd = pulses.map { $0.startedAt.addingTimeInterval($0.duration + 0.15) }.max() ?? now
        let waitSeconds = max(0.6, latestEnd.timeIntervalSince(now))
        pulseCleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(waitSeconds * 1000)))
            guard let self, !Task.isCancelled else { return }
            let cutoff = Date()
            self.activePulses.removeAll { cutoff.timeIntervalSince($0.startedAt) > $0.duration }
        }
    }

    private func resolveCoordinate() async -> GeoCoordinate? {
        if let hardwareCoord = await locationProvider?.currentCoordinate() {
            return hardwareCoord
        }
        if isMockMode {
            return GeoCoordinate(latitude: 10.772612, longitude: 106.657891, accuracyMeters: 6.5)
        }
        return nil
    }
}
#endif
