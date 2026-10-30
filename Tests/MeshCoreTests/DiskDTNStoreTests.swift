import Foundation
import MeshCore
import Testing

@Suite("DiskDTNStore Persistence & Multi-Hop SOS Signal")
struct DiskDTNStoreTests {
    // MARK: - 1. Cold-Restart DTN Outbox & TOFU Key Persistence + Delivery & ACK

    @Test("Persisted DTNOutbox and TOFU pinnedPeers survive cold restart, flush E2EE packet on reconnect, decrypt, and clear on ACK")
    func persistedDTNOutboxAndPinnedPeersSurviveColdRestart() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshPulseTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir
            .appendingPathComponent("Nested", isDirectory: true)
            .appendingPathComponent("live_mesh_state.json", isDirectory: false)
        let store = DiskDTNStore(fileURL: storeURL)

        let baseTime = Date(timeIntervalSince1970: 1_760_000_000)
        let sealerA = SimulatedEnvelopeSealer(seed: "node-a-seed")
        let sealerC = SimulatedEnvelopeSealer(seed: "node-c-seed")

        let identityA = NodeIdentity(
            nodeID: "node-A",
            displayName: "iPhone-A",
            publicKeyBase64: sealerA.publicKeyBase64
        )
        let identityC = NodeIdentity(
            nodeID: "node-C",
            displayName: "iPhone-C",
            publicKeyBase64: sealerC.publicKeyBase64
        )

        // 1. Node A pins Node C's public key, queues an offline E2EE Direct Message, and saves to disk
        var initialRouterA = MeshRouter(localIdentity: identityA)
        initialRouterA.registerPeerIdentity(identityC, lastSeen: baseTime)

        let (msgID, initialEffects) = try initialRouterA.sendChat(
            text: "Hẹn gặp tại trạm cứu hộ suối Đá lúc 06:00.",
            to: identityC.nodeID,
            coordinate: GeoCoordinate(latitude: 10.776889, longitude: 106.700806, accuracyMeters: 5.2),
            sealer: sealerA,
            now: baseTime
        )

        let txExistsWhileOffline = initialEffects.contains { effect in
            if case .transmit = effect { return true }
            return false
        }
        #expect(txExistsWhileOffline == false)
        #expect(initialRouterA.dtnOutbox.count == 1)

        try store.save(initialRouterA.snapshotPersistedState(now: baseTime))
        #expect(FileManager.default.fileExists(atPath: storeURL.path))

        // 2. Simulate full app termination & cold relaunch 120 seconds later
        let restartTime = baseTime.addingTimeInterval(120)
        let loadedState = store.load(now: restartTime)
        #expect(loadedState.outbox.count == 1)
        #expect(loadedState.pinnedPeers == [identityC])

        var restartedRouterA = MeshRouter(localIdentity: identityA)
        restartedRouterA.restorePersistedState(loadedState, now: restartTime)

        #expect(restartedRouterA.dtnOutbox.count == 1)
        #expect(restartedRouterA.knownPeers.count == 1)
        #expect(restartedRouterA.knownPeers.first?.identity == identityC)
        #expect(restartedRouterA.knownPeers.first?.linkKind == .offlineDTN)
        // Restored packet ID must be seeded in seenCache to prevent self-echo loops
        #expect(restartedRouterA.seenCache.contains(msgID, now: restartTime) == true)

        // 3. Reconnect directly to Node C -> restartedRouterA flushes persisted E2EE DTN packet
        var routerC = MeshRouter(localIdentity: identityC)
        _ = routerC.updateDirectPeers([identityA], now: restartTime)
        let reconnectEffectsA = restartedRouterA.updateDirectPeers([identityC], now: restartTime)

        let flushedWireData = try #require(
            reconnectEffectsA.compactMap { effect -> Data? in
                guard case let .transmit(data, packet, peers) = effect,
                      packet.id == msgID,
                      peers == [identityC.nodeID]
                else {
                    return nil
                }
                #expect(packet.isEncrypted == true)
                return data
            }.first
        )

        // 4. Node C receives & opens the E2EE envelope and emits a Delivery Receipt (.ack)
        let arrivalTime = restartTime.addingTimeInterval(0.04)
        let effectsAtC = routerC.handleIncoming(
            rawData: flushedWireData,
            fromDirectPeerID: identityA.nodeID,
            sealer: sealerC,
            now: arrivalTime
        )

        let receivedMessage = try #require(
            effectsAtC.compactMap { effect -> ReceivedMeshMessage? in
                if case let .messageReceived(msg) = effect { return msg }
                return nil
            }.first
        )
        #expect(receivedMessage.id == msgID)
        #expect(receivedMessage.text == "Hẹn gặp tại trạm cứu hộ suối Đá lúc 06:00.")
        #expect(receivedMessage.isEncrypted == true)
        #expect(receivedMessage.coordinate == GeoCoordinate(latitude: 10.776889, longitude: 106.700806, accuracyMeters: 5.2))

        let ackWireData = try #require(
            effectsAtC.compactMap { effect -> Data? in
                guard case let .transmit(data, packet, peers) = effect,
                      packet.type == .ack,
                      peers == [identityA.nodeID]
                else {
                    return nil
                }
                return data
            }.first
        )

        // 5. Restarted Node A receives .ack -> DTNOutbox clears to 0 and persists clean state
        let ackEffectsAtA = restartedRouterA.handleIncoming(
            rawData: ackWireData,
            fromDirectPeerID: identityC.nodeID,
            sealer: sealerA,
            now: arrivalTime.addingTimeInterval(0.03)
        )
        let markedDelivered = ackEffectsAtA.contains { effect in
            if case let .deliveryUpdated(packetID, state, _, _) = effect {
                return packetID == msgID && state == .deliveredAck
            }
            return false
        }
        #expect(markedDelivered == true)
        #expect(restartedRouterA.dtnOutbox.count == 0)

        try store.save(restartedRouterA.snapshotPersistedState(now: arrivalTime.addingTimeInterval(0.05)))
        let reloadedAfterAck = store.load(now: arrivalTime.addingTimeInterval(0.1))
        #expect(reloadedAfterAck.outbox.count == 0)
        #expect(reloadedAfterAck.pinnedPeers == [identityC])
    }

    // MARK: - 2. Expired DTN Pruning & Graceful Corrupted/Missing JSON Recovery

    @Test("DiskDTNStore prunes expired DTN packets on load and recovers cleanly from missing or corrupted JSON")
    func loadPrunesExpiredPacketsAndRecoversFromCorruptedFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshPulseTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("corrupt_or_expired_state.json", isDirectory: false)
        let store = DiskDTNStore(fileURL: storeURL)
        let t0 = Date(timeIntervalSince1970: 1_760_500_000)

        // 1. Missing file returns empty state gracefully
        let missingLoaded = store.load(now: t0)
        #expect(missingLoaded == PersistedMeshState())

        // 2. Save 1 short-lived packet (20s) + 1 long-lived packet (3600s)
        let shortPacket = MeshPacket(
            type: .chat,
            senderID: "node-A",
            senderName: "iPhone-A",
            targetID: "node-B",
            routePath: ["node-A"],
            routeNames: ["iPhone-A"],
            ttl: 4,
            remainingCopies: 4,
            timestamp: t0,
            isEncrypted: false,
            payload: Data("short".utf8)
        )
        let validPacket = MeshPacket(
            type: .chat,
            senderID: "node-A",
            senderName: "iPhone-A",
            targetID: "node-C",
            routePath: ["node-A"],
            routeNames: ["iPhone-A"],
            ttl: 4,
            remainingCopies: 4,
            timestamp: t0,
            isEncrypted: false,
            payload: Data("valid".utf8)
        )

        var outbox = DTNOutbox()
        outbox.enqueue(shortPacket, now: t0, lifetime: 20)
        outbox.enqueue(validPacket, now: t0, lifetime: 3600)
        #expect(outbox.count == 2)

        let pinnedPeer = NodeIdentity(nodeID: "node-C", displayName: "iPhone-C", publicKeyBase64: nil)
        try store.save(PersistedMeshState(outbox: outbox, pinnedPeers: [pinnedPeer]))

        // Load at t0 + 60s -> shortPacket expired and pruned automatically; validPacket remains
        let loadedAfterExpiry = store.load(now: t0.addingTimeInterval(60))
        #expect(loadedAfterExpiry.outbox.count == 1)
        #expect(loadedAfterExpiry.outbox.record(for: shortPacket.id, now: t0.addingTimeInterval(60)) == nil)
        #expect(loadedAfterExpiry.outbox.record(for: validPacket.id, now: t0.addingTimeInterval(60)) != nil)
        #expect(loadedAfterExpiry.pinnedPeers == [pinnedPeer])

        // 3. Overwrite disk file with corrupted garbage bytes -> load() returns empty state without throwing/crashing
        try Data("<<<corrupted-json-payload-{{{[".utf8).write(to: storeURL, options: [.atomic])
        let recoveredFromGarbage = store.load(now: t0.addingTimeInterval(90))
        #expect(recoveredFromGarbage == PersistedMeshState())
        #expect(recoveredFromGarbage.outbox.count == 0)
        #expect(recoveredFromGarbage.pinnedPeers.isEmpty)
    }

    // MARK: - 3. Multi-Hop SOS Signal with Intact Offline GeoCoordinate

    @Test("SOS Signal (ttl = 6) propagates multi-hop A -> B -> C preserving exact GeoCoordinate and accuracyMeters")
    func multiHopSOSSignalPreservesGeoCoordinate() throws {
        var net = SimulatedMeshNetwork()
        // Block direct link A <-> C so SOS must hop A -> B -> C
        net.setSymmetricBlock("iPhone-A", "iPhone-C", isBlocked: true)

        let distressCoord = GeoCoordinate(
            latitude: 16.047079,
            longitude: 108.206230,
            accuracyMeters: 7.8
        )
        let sosID = try net.sendSOS(
            from: "iPhone-A",
            text: "SOS: Sạt lở đèo Hải Vân, cần đội y tế tiếp cận!",
            coordinate: distressCoord,
            ttl: 6
        )

        let nodeB = try #require(net.node("iPhone-B"))
        let nodeC = try #require(net.node("iPhone-C"))

        // 1-hop neighbor B receives SOS directly with initial ttl == 6, then decrements ttl to 5 on relay
        let sosAtB = try #require(nodeB.receivedMessages.first { $0.id == sosID })
        #expect(sosAtB.packetType == .sos)
        #expect(sosAtB.hopCount == 1)
        #expect(sosAtB.remainingTTL == 6)
        #expect(sosAtB.routePath == ["iPhone-A", "iPhone-B"])
        #expect(sosAtB.coordinate == distressCoord)
        #expect(sosAtB.coordinate?.latitude == 16.047079)
        #expect(sosAtB.coordinate?.longitude == 108.206230)
        #expect(sosAtB.coordinate?.accuracyMeters == 7.8)

        // 2-hop node C receives relayed SOS via B with remainingTTL == 5 and identical GeoCoordinate
        let sosAtC = try #require(nodeC.receivedMessages.first { $0.id == sosID })
        #expect(sosAtC.packetType == .sos)
        #expect(sosAtC.hopCount == 2)
        #expect(sosAtC.remainingTTL == 5)
        #expect(sosAtC.routePath == ["iPhone-A", "iPhone-B", "iPhone-C"])
        #expect(sosAtC.routeNames == ["iPhone-A", "iPhone-B", "iPhone-C"])
        #expect(sosAtC.text == "SOS: Sạt lở đèo Hải Vân, cần đội y tế tiếp cận!")
        #expect(sosAtC.coordinate == distressCoord)
        #expect(sosAtC.coordinate?.latitude == 16.047079)
        #expect(sosAtC.coordinate?.longitude == 108.206230)
        #expect(sosAtC.coordinate?.accuracyMeters == 7.8)
    }
}
