#if canImport(MultipeerConnectivity) && canImport(SwiftUI)
import Foundation
import MeshCore
import MultipeerConnectivity
import os

/// Production `MultipeerConnectivity` adapter (BLE + Wi-Fi Direct / AWDL) implementing:
/// - Deterministic lexicographical invitation tie-breaking (`localNodeID > remoteNodeID`)
/// - Hard 7-peer `MCSession` saturation ceiling (Stute et al., ACM CoNEXT 2018)
/// - UTF-8-safe `<= 63`-byte `MCPeerID` & compact `< 200`-byte Bonjour TXT `discoveryInfo`
/// - Context-carried `NodeIdentity` handshake & exponential backoff reconnect (`1.5s -> 15s`)
/// - Multi-subscriber `AsyncStream<TransportEvent>` fan-out with immediate initial snapshot
@MainActor
public final class MultipeerTransport: MeshTransportAdapter {
    public nonisolated static let maxConnectedPeers = 7
    private nonisolated static let maxPeerIDUTF8Bytes = 63
    private nonisolated static let maxDiscoveryNameUTF8Bytes = 40
    private nonisolated static let maxDiscoveryPubKeyUTF8Bytes = 120

    private let engine: RadioEngine
    private var forwarderTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<TransportEvent>.Continuation] = [:]

    public init() {
        let (engineStream, engineContinuation) = AsyncStream.makeStream(of: TransportEvent.self)
        let radioEngine = RadioEngine(eventContinuation: engineContinuation)
        self.engine = radioEngine

        self.forwarderTask = Task { @MainActor [weak self] in
            for await event in engineStream {
                guard let self else { break }
                self.fanOut(event)
            }
        }
    }

    deinit {
        forwarderTask?.cancel()
        engine.shutdown()
    }

    // MARK: - MeshTransportAdapter

    public var events: AsyncStream<TransportEvent> {
        let subscriberID = UUID()
        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            self.continuations[subscriberID] = continuation

            let snapshot = self.engine.currentSnapshot()
            continuation.yield(
                .radioStateChanged(isRunning: snapshot.isRunning, statusNote: snapshot.statusNote)
            )
            if snapshot.isRunning {
                continuation.yield(.peersChanged(snapshot.connectedPeers))
            }

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.removeContinuation(id: subscriberID)
                }
            }
        }
    }

    public func start(localIdentity: NodeIdentity) {
        engine.startOrRefresh(localIdentity: localIdentity)
    }

    public func stop() {
        engine.stop()
    }

    public func updateLocalIdentity(_ identity: NodeIdentity) {
        engine.updateLocalIdentity(identity)
    }

    public func send(_ data: Data, toPeerIDs peerIDs: [String]) {
        engine.send(data, toNodeIDs: peerIDs)
    }

    // MARK: - Stream Fan-Out

    private func fanOut(_ event: TransportEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    // MARK: - UTF-8 & TXT Record Sanitization Helpers

    nonisolated static func sanitizedPeerDisplayName(displayName: String, nodeID: String) -> String {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNode = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)

        let candidate: String
        if !trimmedName.isEmpty && !trimmedNode.isEmpty {
            let shortSuffix = String(trimmedNode.suffix(6))
            let maxPrefixBytes = max(8, maxPeerIDUTF8Bytes - shortSuffix.utf8.count - 1)
            let safePrefix = truncateUTF8(trimmedName, maxBytes: maxPrefixBytes)
            candidate = "\(safePrefix)·\(shortSuffix)"
        } else if !trimmedName.isEmpty {
            candidate = trimmedName
        } else if !trimmedNode.isEmpty {
            candidate = trimmedNode
        } else {
            candidate = "MeshPulseNode"
        }

        let truncated = truncateUTF8(candidate, maxBytes: maxPeerIDUTF8Bytes)
        return truncated.isEmpty ? "MeshNode" : truncated
    }

    nonisolated static func makeDiscoveryInfo(for identity: NodeIdentity) -> [String: String] {
        let safeNodeID = truncateUTF8(identity.nodeID, maxBytes: 32)
        let safeName = truncateUTF8(identity.displayName, maxBytes: maxDiscoveryNameUTF8Bytes)
        let rawPubKey = identity.publicKeyBase64 ?? ""
        let safePubKey = rawPubKey.utf8.count <= maxDiscoveryPubKeyUTF8Bytes ? rawPubKey : ""

        return [
            "nodeID": safeNodeID,
            "name": safeName,
            "pubKey": safePubKey,
        ]
    }

    nonisolated static func truncateUTF8(_ input: String, maxBytes: Int) -> String {
        guard maxBytes > 0, !input.isEmpty else { return "" }
        if input.utf8.count <= maxBytes {
            return input
        }
        var result = ""
        result.reserveCapacity(min(input.count, maxBytes))
        var usedBytes = 0
        for character in input {
            let charBytes = character.utf8.count
            if usedBytes + charBytes > maxBytes {
                break
            }
            result.append(character)
            usedBytes += charBytes
        }
        return result
    }
}

// MARK: - Lock-Protected Non-Isolated MultipeerConnectivity Delegate Core

private final class RadioEngine: NSObject,
    MCSessionDelegate,
    MCNearbyServiceBrowserDelegate,
    MCNearbyServiceAdvertiserDelegate,
    @unchecked Sendable
{
    struct Snapshot: Sendable {
        let isRunning: Bool
        let statusNote: String?
        let connectedPeers: [NodeIdentity]
    }

    private static let inviteTimeoutSeconds: TimeInterval = 12.0
    private static let baseBackoffSeconds: TimeInterval = 1.5
    private static let maxBackoffSeconds: TimeInterval = 15.0

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.haole2k4.MeshPulse", category: "MultipeerTransport")
    private let eventContinuation: AsyncStream<TransportEvent>.Continuation

    // Protected mutable state (accessed exclusively under `lock`)
    private var isRunning = false
    private var statusNote: String? = "Sẵn sàng kết nối BLE + Wi-Fi Direct (AWDL)"
    private var localIdentity = NodeIdentity(nodeID: "node-init", displayName: "MeshNode")
    private var localPeerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private var identityByPeer: [MCPeerID: NodeIdentity] = [:]
    private var peerByNodeID: [String: MCPeerID] = [:]
    private var peerStates: [MCPeerID: MCSessionState] = [:]
    private var discoveredNodeIDs: Set<String> = []
    private var lastInviteSentAt: [String: Date] = [:]
    private var reconnectAttempts: [String: Int] = [:]
    private var reconnectTasks: [String: Task<Void, Never>] = [:]

    init(eventContinuation: AsyncStream<TransportEvent>.Continuation) {
        self.eventContinuation = eventContinuation
        super.init()
    }

    func currentSnapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            isRunning: isRunning,
            statusNote: statusNote,
            connectedPeers: connectedPeerIdentitiesLocked()
        )
    }

    func startOrRefresh(localIdentity newIdentity: NodeIdentity) {
        lock.lock()
        let existingSession = isRunning ? session : nil
        let existingPeerID = isRunning ? localPeerID : nil
        lock.unlock()

        // Query MCSession.connectedPeers outside `lock` so `lock` stays a pure leaf lock (no ABBA lock inversion).
        let liveConnectedSnapshot: Set<MCPeerID>? = existingSession.map { Set($0.connectedPeers) }
        let discoveryInfo = MultipeerTransport.makeDiscoveryInfo(for: newIdentity)

        var eventsToEmit: [TransportEvent] = []
        var advertiserToStop: MCNearbyServiceAdvertiser?
        var browserToStop: MCNearbyServiceBrowser?
        var advertiserToStart: MCNearbyServiceAdvertiser?
        var browserToStart: MCNearbyServiceBrowser?

        if let activePeerID = existingPeerID {
            let freshAdvertiser = MCNearbyServiceAdvertiser(
                peer: activePeerID,
                discoveryInfo: discoveryInfo,
                serviceType: MeshPacket.serviceType
            )
            freshAdvertiser.delegate = self

            let freshBrowser = MCNearbyServiceBrowser(
                peer: activePeerID,
                serviceType: MeshPacket.serviceType
            )
            freshBrowser.delegate = self

            lock.lock()
            self.localIdentity = newIdentity
            if isRunning, self.localPeerID === activePeerID {
                if let liveSet = liveConnectedSnapshot {
                    for (peer, state) in peerStates where state == .connected && !liveSet.contains(peer) {
                        peerStates[peer] = .notConnected
                    }
                }
                advertiserToStop = self.advertiser
                browserToStop = self.browser
                self.advertiser = freshAdvertiser
                self.browser = freshBrowser

                let peersSnapshot = connectedPeerIdentitiesLocked()
                let note =
                    peersSnapshot.isEmpty
                    ? "Đang phát & quét BLE / Wi-Fi Direct (AWDL)"
                    : "Đã kết nối trực tiếp \(peersSnapshot.count)/\(MultipeerTransport.maxConnectedPeers) trạm AWDL"
                self.statusNote = note

                advertiserToStart = freshAdvertiser
                browserToStart = freshBrowser
                eventsToEmit.append(.radioStateChanged(isRunning: true, statusNote: note))
                eventsToEmit.append(.peersChanged(peersSnapshot))
            }
            lock.unlock()
        } else {
            let safePeerName = MultipeerTransport.sanitizedPeerDisplayName(
                displayName: newIdentity.displayName,
                nodeID: newIdentity.nodeID
            )
            let createdPeerID = MCPeerID(displayName: safePeerName)
            let createdSession = MCSession(
                peer: createdPeerID,
                securityIdentity: nil,
                encryptionPreference: .required
            )
            createdSession.delegate = self

            let createdAdvertiser = MCNearbyServiceAdvertiser(
                peer: createdPeerID,
                discoveryInfo: discoveryInfo,
                serviceType: MeshPacket.serviceType
            )
            createdAdvertiser.delegate = self

            let createdBrowser = MCNearbyServiceBrowser(
                peer: createdPeerID,
                serviceType: MeshPacket.serviceType
            )
            createdBrowser.delegate = self

            lock.lock()
            self.localIdentity = newIdentity
            self.localPeerID = createdPeerID
            self.session = createdSession
            self.advertiser = createdAdvertiser
            self.browser = createdBrowser
            self.isRunning = true
            self.statusNote = "Đang phát & quét BLE / Wi-Fi Direct (AWDL)"

            advertiserToStart = createdAdvertiser
            browserToStart = createdBrowser
            eventsToEmit.append(.radioStateChanged(isRunning: true, statusNote: self.statusNote))
            eventsToEmit.append(.peersChanged([]))
            lock.unlock()
        }

        advertiserToStop?.delegate = nil
        advertiserToStop?.stopAdvertisingPeer()
        browserToStop?.delegate = nil
        browserToStop?.stopBrowsingForPeers()

        advertiserToStart?.startAdvertisingPeer()
        browserToStart?.startBrowsingForPeers()

        for event in eventsToEmit {
            eventContinuation.yield(event)
        }
    }

    func stop() {
        let resources = tearDownLocked(newStatusNote: "Đã tạm tắt sóng ngoại tuyến")
        cleanupResourcesOutsideLock(resources)
        eventContinuation.yield(.radioStateChanged(isRunning: false, statusNote: "Đã tạm tắt sóng ngoại tuyến"))
        eventContinuation.yield(.peersChanged([]))
    }

    func shutdown() {
        let resources = tearDownLocked(newStatusNote: nil)
        cleanupResourcesOutsideLock(resources)
        eventContinuation.finish()
    }

    func updateLocalIdentity(_ updatedIdentity: NodeIdentity) {
        lock.lock()
        let changed =
            localIdentity.displayName != updatedIdentity.displayName
            || localIdentity.publicKeyBase64 != updatedIdentity.publicKeyBase64
        localIdentity = updatedIdentity
        let activePeerID: MCPeerID? = (isRunning && changed) ? localPeerID : nil
        lock.unlock()

        guard let activePeerID else { return }

        let freshAdvertiser = MCNearbyServiceAdvertiser(
            peer: activePeerID,
            discoveryInfo: MultipeerTransport.makeDiscoveryInfo(for: updatedIdentity),
            serviceType: MeshPacket.serviceType
        )
        freshAdvertiser.delegate = self

        var oldAdvertiser: MCNearbyServiceAdvertiser?
        var shouldStartNew = false

        lock.lock()
        if isRunning, self.localPeerID === activePeerID {
            oldAdvertiser = self.advertiser
            self.advertiser = freshAdvertiser
            shouldStartNew = true
        }
        lock.unlock()

        oldAdvertiser?.delegate = nil
        oldAdvertiser?.stopAdvertisingPeer()
        if shouldStartNew {
            freshAdvertiser.startAdvertisingPeer()
        } else {
            freshAdvertiser.delegate = nil
        }
    }

    func send(_ data: Data, toNodeIDs nodeIDs: [String]) {
        guard !data.isEmpty, !nodeIDs.isEmpty else { return }

        lock.lock()
        guard isRunning, let activeSession = session else {
            lock.unlock()
            return
        }

        var targetMCPeers: [MCPeerID] = []
        targetMCPeers.reserveCapacity(nodeIDs.count)

        for nodeID in Set(nodeIDs) {
            if let mappedPeer = peerByNodeID[nodeID], peerStates[mappedPeer] == .connected {
                targetMCPeers.append(mappedPeer)
            } else if let fallbackPeer = peerStates.first(where: { $0.value == .connected && identityByPeer[$0.key]?.nodeID == nodeID })?.key {
                targetMCPeers.append(fallbackPeer)
            }
        }
        lock.unlock()

        guard !targetMCPeers.isEmpty else { return }
        do {
            try activeSession.send(data, toPeers: targetMCPeers, with: .reliable)
        } catch {
            logger.error("MCSession send failed (\(data.count) bytes): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - MCNearbyServiceBrowserDelegate

    func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        let remoteNodeID = (info?["nodeID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remoteNodeID.isEmpty else { return }

        let rawName = (info?["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = rawName.isEmpty ? peerID.displayName : rawName
        let rawPubKey = (info?["pubKey"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPubKey: String? = rawPubKey.isEmpty ? nil : rawPubKey

        var inviteAction: (MCNearbyServiceBrowser, MCPeerID, MCSession, Data)?
        var updatedConnectedEvent: TransportEvent?

        lock.lock()
        guard isRunning, self.browser === browser, remoteNodeID != localIdentity.nodeID else {
            lock.unlock()
            return
        }

        let previousIdentity = identityByPeer[peerID]
        let mergedPubKey = previousIdentity?.publicKeyBase64 ?? resolvedPubKey
        let remoteIdentity = NodeIdentity(
            nodeID: remoteNodeID,
            displayName: resolvedName,
            publicKeyBase64: mergedPubKey
        )
        identityByPeer[peerID] = remoteIdentity
        peerByNodeID[remoteNodeID] = peerID
        discoveredNodeIDs.insert(remoteNodeID)

        if peerStates[peerID] == .connected, previousIdentity != remoteIdentity {
            updatedConnectedEvent = .peersChanged(connectedPeerIdentitiesLocked())
        }

        if shouldInitiateInviteLocked(toRemoteNodeID: remoteNodeID, peerID: peerID),
           let activeBrowser = self.browser,
           let activeSession = self.session
        {
            let contextData = encodeIdentityJSON(localIdentity)
            lastInviteSentAt[remoteNodeID] = Date()
            inviteAction = (activeBrowser, peerID, activeSession, contextData)
        }
        lock.unlock()

        if let updatedConnectedEvent {
            eventContinuation.yield(updatedConnectedEvent)
        }
        if let (activeBrowser, targetPeer, activeSession, contextData) = inviteAction {
            activeBrowser.invitePeer(
                targetPeer,
                to: activeSession,
                withContext: contextData,
                timeout: Self.inviteTimeoutSeconds
            )
            scheduleInviteWatchdog(forRemoteNodeID: remoteNodeID)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        var taskToCancel: Task<Void, Never>?

        lock.lock()
        guard self.browser === browser else {
            lock.unlock()
            return
        }
        if let nodeID = identityByPeer[peerID]?.nodeID {
            if peerByNodeID[nodeID] == peerID {
                discoveredNodeIDs.remove(nodeID)
                reconnectAttempts.removeValue(forKey: nodeID)
                taskToCancel = reconnectTasks.removeValue(forKey: nodeID)
            }
        }
        lock.unlock()

        taskToCancel?.cancel()
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) {
        let message = "Không thể quét mạng cục bộ: \(error.localizedDescription)"
        logger.error("\(message, privacy: .public)")

        lock.lock()
        guard isRunning, self.browser === browser else {
            lock.unlock()
            return
        }
        statusNote = message
        lock.unlock()

        eventContinuation.yield(.radioStateChanged(isRunning: true, statusNote: message))
    }

    // MARK: - MCNearbyServiceAdvertiserDelegate

    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let decodedContextIdentity: NodeIdentity? = {
            guard let context, !context.isEmpty else { return nil }
            return try? JSONDecoder().decode(NodeIdentity.self, from: context)
        }()

        var shouldAccept = false
        var targetSession: MCSession?

        lock.lock()
        if isRunning, self.advertiser === advertiser, let activeSession = session {
            let knownIdentity = identityByPeer[peerID]
            let resolvedIdentity: NodeIdentity? = {
                if let decoded = decodedContextIdentity {
                    let pub = knownIdentity?.publicKeyBase64 ?? decoded.publicKeyBase64
                    return NodeIdentity(
                        nodeID: decoded.nodeID,
                        displayName: decoded.displayName,
                        publicKeyBase64: pub
                    )
                }
                return knownIdentity
            }()

            if let remote = resolvedIdentity, remote.nodeID != localIdentity.nodeID {
                let activeOrConnectingExcludingRemote = peerStates.reduce(into: Set<String>()) { acc, entry in
                    guard entry.value == .connected || entry.value == .connecting,
                          let id = identityByPeer[entry.key]?.nodeID,
                          id != localIdentity.nodeID,
                          id != remote.nodeID
                    else { return }
                    acc.insert(id)
                }.count
                let alreadyConnectedSamePeer = (peerStates[peerID] == .connected)
                let tieBreakAllows =
                    (remote.nodeID > localIdentity.nodeID)
                    || !discoveredNodeIDs.contains(remote.nodeID)

                if activeOrConnectingExcludingRemote < MultipeerTransport.maxConnectedPeers,
                   !alreadyConnectedSamePeer,
                   tieBreakAllows
                {
                    identityByPeer[peerID] = remote
                    peerByNodeID[remote.nodeID] = peerID
                    peerStates[peerID] = .connecting
                    shouldAccept = true
                    targetSession = activeSession
                }
            }
        }
        lock.unlock()

        invitationHandler(shouldAccept, shouldAccept ? targetSession : nil)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error) {
        let message = "Không thể quảng bá dịch vụ P2P: \(error.localizedDescription)"
        logger.error("\(message, privacy: .public)")

        lock.lock()
        guard isRunning, self.advertiser === advertiser else {
            lock.unlock()
            return
        }
        statusNote = message
        lock.unlock()

        eventContinuation.yield(.radioStateChanged(isRunning: true, statusNote: message))
    }

    // MARK: - MCSessionDelegate

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        var peersSnapshot: [NodeIdentity]?
        var taskToCancel: Task<Void, Never>?
        var reconnectNodeID: String?
        var statusUpdate: String?

        lock.lock()
        guard isRunning, self.session === session else {
            lock.unlock()
            return
        }

        peerStates[peerID] = state
        let remoteNodeID = identityByPeer[peerID]?.nodeID

        switch state {
        case .connected:
            if let remoteNodeID {
                lastInviteSentAt.removeValue(forKey: remoteNodeID)
                reconnectAttempts.removeValue(forKey: remoteNodeID)
                taskToCancel = reconnectTasks.removeValue(forKey: remoteNodeID)
            }
            let connected = connectedPeerIdentitiesLocked()
            peersSnapshot = connected
            statusUpdate =
                connected.isEmpty
                ? "Đang phát & quét BLE / Wi-Fi Direct (AWDL)"
                : "Đã kết nối trực tiếp \(connected.count)/\(MultipeerTransport.maxConnectedPeers) trạm AWDL"
            self.statusNote = statusUpdate

        case .connecting:
            break

        case .notConnected:
            if let remoteNodeID {
                lastInviteSentAt.removeValue(forKey: remoteNodeID)
                if discoveredNodeIDs.contains(remoteNodeID),
                   localIdentity.nodeID > remoteNodeID,
                   connectedPeerIdentitiesLocked().count < MultipeerTransport.maxConnectedPeers
                {
                    reconnectNodeID = remoteNodeID
                }
            }
            let connected = connectedPeerIdentitiesLocked()
            peersSnapshot = connected
            statusUpdate =
                connected.isEmpty
                ? "Đang phát & quét BLE / Wi-Fi Direct (AWDL)"
                : "Đã kết nối trực tiếp \(connected.count)/\(MultipeerTransport.maxConnectedPeers) trạm AWDL"
            self.statusNote = statusUpdate

        @unknown default:
            break
        }
        lock.unlock()

        taskToCancel?.cancel()

        if let statusUpdate {
            eventContinuation.yield(.radioStateChanged(isRunning: true, statusNote: statusUpdate))
        }
        if let peersSnapshot {
            eventContinuation.yield(.peersChanged(peersSnapshot))
        }
        if let reconnectNodeID {
            scheduleExponentialReconnect(forRemoteNodeID: reconnectNodeID)
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard !data.isEmpty else { return }

        lock.lock()
        let senderNodeID: String? =
            (isRunning && self.session === session)
            ? identityByPeer[peerID]?.nodeID
            : nil
        lock.unlock()

        if let senderNodeID {
            eventContinuation.yield(.dataReceived(data, fromPeerID: senderNodeID))
        }
    }

    func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {
        stream.close()
    }

    func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: (any Error)?
    ) {}

    // MARK: - Tie-Break, Exponential Backoff & Cleanup Helpers

    private func shouldInitiateInviteLocked(toRemoteNodeID remoteNodeID: String, peerID: MCPeerID) -> Bool {
        guard localIdentity.nodeID > remoteNodeID else { return false }
        let connected = connectedPeerIdentitiesLocked()
        guard connected.count < MultipeerTransport.maxConnectedPeers else { return false }
        guard !connected.contains(where: { $0.nodeID == remoteNodeID }) else { return false }

        if peerStates[peerID] == .connecting || peerStates[peerID] == .connected {
            return false
        }
        if let lastSent = lastInviteSentAt[remoteNodeID],
           Date().timeIntervalSince(lastSent) < Self.inviteTimeoutSeconds
        {
            return false
        }
        return true
    }

    private func connectedPeerIdentitiesLocked() -> [NodeIdentity] {
        guard session != nil else { return [] }
        var byNodeID: [String: NodeIdentity] = [:]

        for (peer, state) in peerStates where state == .connected {
            guard let identity = identityByPeer[peer],
                  identity.nodeID != localIdentity.nodeID
            else { continue }
            byNodeID[identity.nodeID] = identity
        }

        return byNodeID.values
            .sorted { $0.nodeID < $1.nodeID }
            .prefix(MultipeerTransport.maxConnectedPeers)
            .map { $0 }
    }

    private func scheduleInviteWatchdog(forRemoteNodeID remoteNodeID: String) {
        // If an invite times out without firing a session state transition while peer remains discovered,
        // fall into exponential backoff reconnect.
        lock.lock()
        guard reconnectTasks[remoteNodeID] == nil else {
            lock.unlock()
            return
        }
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int((Self.inviteTimeoutSeconds + 0.5) * 1000)))
            guard let self, !Task.isCancelled else { return }
            self.triggerBackoffIfStillDisconnected(remoteNodeID: remoteNodeID)
        }
        reconnectTasks[remoteNodeID] = task
        lock.unlock()
    }

    private func triggerBackoffIfStillDisconnected(remoteNodeID: String) {
        var needsReconnect = false
        lock.lock()
        reconnectTasks.removeValue(forKey: remoteNodeID)
        if isRunning,
           discoveredNodeIDs.contains(remoteNodeID),
           localIdentity.nodeID > remoteNodeID,
           !connectedPeerIdentitiesLocked().contains(where: { $0.nodeID == remoteNodeID })
        {
            if let peer = peerByNodeID[remoteNodeID], peerStates[peer] != .connecting, peerStates[peer] != .connected {
                needsReconnect = true
            }
        }
        lock.unlock()

        if needsReconnect {
            scheduleExponentialReconnect(forRemoteNodeID: remoteNodeID)
        }
    }

    private func scheduleExponentialReconnect(forRemoteNodeID remoteNodeID: String) {
        lock.lock()
        reconnectTasks[remoteNodeID]?.cancel()
        let attempt = reconnectAttempts[remoteNodeID] ?? 0
        reconnectAttempts[remoteNodeID] = attempt + 1
        let delaySeconds = min(
            Self.maxBackoffSeconds,
            Self.baseBackoffSeconds * pow(2.0, Double(min(attempt, 4)))
        )

        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delaySeconds * 1000)))
            guard let self, !Task.isCancelled else { return }
            self.attemptReconnectInvite(toRemoteNodeID: remoteNodeID)
        }
        reconnectTasks[remoteNodeID] = task
        lock.unlock()
    }

    private func attemptReconnectInvite(toRemoteNodeID remoteNodeID: String) {
        var inviteAction: (MCNearbyServiceBrowser, MCPeerID, MCSession, Data)?

        lock.lock()
        reconnectTasks.removeValue(forKey: remoteNodeID)
        if isRunning,
           discoveredNodeIDs.contains(remoteNodeID),
           let targetPeer = peerByNodeID[remoteNodeID],
           shouldInitiateInviteLocked(toRemoteNodeID: remoteNodeID, peerID: targetPeer),
           let activeBrowser = browser,
           let activeSession = session
        {
            let contextData = encodeIdentityJSON(localIdentity)
            lastInviteSentAt[remoteNodeID] = Date()
            inviteAction = (activeBrowser, targetPeer, activeSession, contextData)
        }
        lock.unlock()

        if let (activeBrowser, targetPeer, activeSession, contextData) = inviteAction {
            activeBrowser.invitePeer(
                targetPeer,
                to: activeSession,
                withContext: contextData,
                timeout: Self.inviteTimeoutSeconds
            )
            scheduleInviteWatchdog(forRemoteNodeID: remoteNodeID)
        }
    }

    private func encodeIdentityJSON(_ identity: NodeIdentity) -> Data {
        (try? JSONEncoder().encode(identity)) ?? Data()
    }

    private struct TornDownResources {
        let advertiser: MCNearbyServiceAdvertiser?
        let browser: MCNearbyServiceBrowser?
        let session: MCSession?
        let tasks: [Task<Void, Never>]
    }

    private func tearDownLocked(newStatusNote: String?) -> TornDownResources {
        lock.lock()
        defer { lock.unlock() }

        isRunning = false
        statusNote = newStatusNote

        let oldAdvertiser = advertiser
        let oldBrowser = browser
        let oldSession = session
        let pendingTasks = Array(reconnectTasks.values)

        advertiser = nil
        browser = nil
        session = nil
        localPeerID = nil

        identityByPeer.removeAll()
        peerByNodeID.removeAll()
        peerStates.removeAll()
        discoveredNodeIDs.removeAll()
        lastInviteSentAt.removeAll()
        reconnectAttempts.removeAll()
        reconnectTasks.removeAll()

        return TornDownResources(
            advertiser: oldAdvertiser,
            browser: oldBrowser,
            session: oldSession,
            tasks: pendingTasks
        )
    }

    private func cleanupResourcesOutsideLock(_ resources: TornDownResources) {
        for task in resources.tasks {
            task.cancel()
        }
        resources.advertiser?.delegate = nil
        resources.advertiser?.stopAdvertisingPeer()
        resources.browser?.delegate = nil
        resources.browser?.stopBrowsingForPeers()
        resources.session?.delegate = nil
        resources.session?.disconnect()
    }
}
#endif
