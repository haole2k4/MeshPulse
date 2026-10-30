import Foundation
import MeshCore
import Testing

@Suite("MeshRouter, E2EE Seam, DTNOutbox & Multi-Node Simulation")
struct MeshRouterTests {
    // MARK: - Scenario 1: Direct 1-Hop P2P

    @Test("Scenario 1: Direct 1-hop P2P A -> B delivers with ACK and zero relays")
    func directOneHopP2PWithAck() throws {
        var net = SimulatedMeshNetwork()
        let msgID = try net.sendChat(
            from: SimulatedMeshNetwork.nodeAID,
            to: SimulatedMeshNetwork.nodeBID,
            text: "Chào trực tiếp 1-Hop!"
        )

        let nodeA = try #require(net.node(SimulatedMeshNetwork.nodeAID))
        let nodeB = try #require(net.node(SimulatedMeshNetwork.nodeBID))
        let nodeC = try #require(net.node(SimulatedMeshNetwork.nodeCID))

        #expect(nodeB.receivedMessages.count == 1)
        let received = try #require(nodeB.receivedMessages.first)
        #expect(received.id == msgID)
        #expect(received.text == "Chào trực tiếp 1-Hop!")
        #expect(received.isEncrypted == true)
        #expect(received.hopCount == 1)
        #expect(received.routeNames == ["iPhone-A", "iPhone-B"])

        #expect(nodeA.deliveryStates[msgID] == .deliveredAck)
        #expect(nodeA.router.dtnOutbox.count == 0)
        #expect(nodeB.router.telemetry.relayedPackets == 0)
        #expect(nodeC.router.telemetry.relayedPackets == 0)
    }

    // MARK: - Scenario 2: Topology Blocker + Multi-Hop E2EE Relay Blindness

    @Test("Scenario 2: Topology Blocker drops direct ingress without polluting seenCache; E2EE relays A -> B -> C with blind relay B")
    func topologyBlockerMultiHopBlindRelayE2EE() throws {
        var net = SimulatedMeshNetwork()
        #expect(net.hasPhysicalLink("iPhone-A", "iPhone-C"))

        // Enable Topology Blocker between A and C while physical link A—C remains present
        net.setSymmetricBlock("iPhone-A", "iPhone-C", isBlocked: true)

        // Dispatch E2EE 1-to-1 message from A to C without auto-settling so we can inspect in-flight frames
        let msgID = try net.sendChat(
            from: "iPhone-A",
            to: "iPhone-C",
            text: "Tọa độ mật khu vực B2",
            settle: false
        )

        let inFlight = try #require(net.pendingWireFrames.first { $0.packet.id == msgID })
        #expect(inFlight.toNodeID == "iPhone-B")
        #expect(inFlight.packet.isEncrypted == true)

        // 1. Simulate over-the-air direct frame A -> C arriving at C's ingress FIRST
        net.injectDirectFrame(rawData: inFlight.data, from: "iPhone-A", to: "iPhone-C")

        let nodeCAfterDrop = try #require(net.node("iPhone-C"))
        #expect(nodeCAfterDrop.router.telemetry.blockedIngressDrops == 1)
        #expect(nodeCAfterDrop.packetLogs.contains { $0.direction == .dropBlocked && $0.packetID == msgID })
        // CRITICAL: Blocked ingress packet MUST NOT pollute C's BoundedSeenCache!
        #expect(nodeCAfterDrop.router.seenCache.contains(msgID, now: net.currentTime) == false)

        // 2. Intermediate relay B tries to open E2EE ciphertext -> MUST throw authenticationFailed!
        let nodeA = try #require(net.node("iPhone-A"))
        let nodeB = try #require(net.node("iPhone-B"))
        let nodeC = try #require(net.node("iPhone-C"))

        #expect(throws: MeshCryptoError.authenticationFailed) {
            _ = try nodeB.sealer.open(
                ciphertext: inFlight.packet.payload,
                senderPublicKeyBase64: nodeA.sealer.publicKeyBase64
            )
        }

        // Also verify 1-byte ciphertext tampering throws authenticationFailed even on intended recipient C
        var tamperedPayload = inFlight.packet.payload
        tamperedPayload[tamperedPayload.count / 2] ^= 0xFF
        #expect(throws: MeshCryptoError.authenticationFailed) {
            _ = try nodeC.sealer.open(
                ciphertext: tamperedPayload,
                senderPublicKeyBase64: nodeA.sealer.publicKeyBase64
            )
        }

        // 3. Settle wire queue: packet travels A -> B -> C and ACK returns C -> B -> A
        net.runUntilQuiescent()

        let finalA = try #require(net.node("iPhone-A"))
        let finalB = try #require(net.node("iPhone-B"))
        let finalC = try #require(net.node("iPhone-C"))

        #expect(finalB.receivedMessages.isEmpty)
        #expect(finalB.router.telemetry.relayedPackets >= 2) // Relayed both .chat and .ack

        #expect(finalC.receivedMessages.count == 1)
        let delivered = try #require(finalC.receivedMessages.first)
        #expect(delivered.id == msgID)
        #expect(delivered.text == "Tọa độ mật khu vực B2")
        #expect(delivered.hopCount == 2)
        #expect(delivered.routeNames == ["iPhone-A", "iPhone-B", "iPhone-C"])

        #expect(finalA.deliveryStates[msgID] == .deliveredAck)
        #expect(finalA.deliveryRoutes[msgID] == ["iPhone-C", "iPhone-B", "iPhone-A"])
        #expect(finalA.router.dtnOutbox.count == 0)
    }

    @Test("Scenario 2b: Asymmetric one-sided Topology Blocker on A only still completes ACK via C -> B -> A")
    func asymmetricTopologyBlockerOnSenderOnly() throws {
        var net = SimulatedMeshNetwork()
        // Only A blocks C; C does NOT block A!
        net.setPeerBlocked(on: "iPhone-A", blocking: "iPhone-C", isBlocked: true)

        let msgID = try net.sendChat(
            from: "iPhone-A",
            to: "iPhone-C",
            text: "Kiểm thử chặn một chiều trên máy A"
        )

        let finalA = try #require(net.node("iPhone-A"))
        let finalC = try #require(net.node("iPhone-C"))

        #expect(finalC.receivedMessages.count == 1)
        // Direct ACK C -> A hit A's ingress blocker without polluting seenCache, allowing C -> B -> A ACK through!
        #expect(finalA.router.telemetry.blockedIngressDrops >= 1)
        #expect(finalA.deliveryStates[msgID] == .deliveredAck)
    }

    // MARK: - Scenario 3: Closed Triangle Broadcast Loop Prevention & Zero ACK Storm

    @Test("Scenario 3: Closed triangle A-B-C-A broadcast delivers once per node, drops duplicates, and emits zero ACKs")
    func closedTriangleBroadcastLoopSuppressionAndNoAckStorm() throws {
        var net = SimulatedMeshNetwork()

        let broadcastID = try net.sendChat(
            from: "iPhone-A",
            to: MeshPacket.broadcastTarget,
            text: "Thông báo toàn mạng ngoại tuyến!"
        )

        let nodeA = try #require(net.node("iPhone-A"))
        let nodeB = try #require(net.node("iPhone-B"))
        let nodeC = try #require(net.node("iPhone-C"))

        #expect(nodeB.receivedMessages.count == 1)
        #expect(nodeC.receivedMessages.count == 1)
        #expect(nodeB.receivedMessages.first?.id == broadcastID)
        #expect(nodeC.receivedMessages.first?.id == broadcastID)

        // Looped copies B -> C and C -> B must be suppressed by BoundedSeenCache
        let totalDuplicatesDropped =
            nodeA.router.telemetry.droppedDuplicates
            + nodeB.router.telemetry.droppedDuplicates
            + nodeC.router.telemetry.droppedDuplicates
        #expect(totalDuplicatesDropped >= 2)

        // Absolutely ZERO .ack packets may be generated for Broadcast!
        let allLogs = nodeA.packetLogs + nodeB.packetLogs + nodeC.packetLogs
        #expect(allLogs.contains { $0.packetType == .ack } == false)
    }

    // MARK: - Scenario 4: Binary Spray-and-Wait Quota Halving & Wait Phase

    @Test("Scenario 4: Binary Spray-and-Wait halves quota (4 -> 2 -> 1), holds in Wait phase against D, and delivers directly to C")
    func binarySprayAndWaitQuotaAndWaitPhase() throws {
        var net = SimulatedMeshNetwork(
            nodeSpecs: [
                ("iPhone-A", "iPhone-A", "seed-a"),
                ("iPhone-B", "iPhone-B", "seed-b"),
                ("iPhone-C", "iPhone-C", "seed-c"),
                ("iPhone-D", "iPhone-D", "seed-d"),
                ("iPhone-E", "iPhone-E", "seed-e"),
            ],
            initialLinks: [("iPhone-A", "iPhone-B")],
            routingStrategy: .sprayAndWait,
            initialSprayCopies: 4
        )

        // 1. A sends to offline C while connected only to B: quota splits 4 -> 2 kept on A, 2 sprayed to B
        let msgID = try net.sendChat(
            from: "iPhone-A",
            to: "iPhone-C",
            text: "Gói tin Spray-and-Wait L=4"
        )

        let recordOnA = try #require(net.node("iPhone-A")?.router.dtnOutbox.record(for: msgID, now: net.currentTime))
        let recordOnB = try #require(net.node("iPhone-B")?.router.dtnOutbox.record(for: msgID, now: net.currentTime))
        #expect(recordOnA.packet.remainingCopies == 2)
        #expect(recordOnB.packet.remainingCopies == 2)

        // 2. Isolate B from A, then B meets intermediate node E -> B splits 2 -> 1 (entering Wait phase!)
        net.removePhysicalLink("iPhone-A", "iPhone-B")
        net.addPhysicalLink("iPhone-B", "iPhone-E")

        let recordOnBAfterE = try #require(
            net.node("iPhone-B")?.router.dtnOutbox.record(for: msgID, now: net.currentTime)
        )
        let recordOnE = try #require(
            net.node("iPhone-E")?.router.dtnOutbox.record(for: msgID, now: net.currentTime)
        )
        #expect(recordOnBAfterE.packet.remainingCopies == 1)
        #expect(recordOnE.packet.remainingCopies == 1)
        net.removePhysicalLink("iPhone-B", "iPhone-E")

        // 3. Wait Phase Check: B (remainingCopies == 1) meets intermediate node D (D != C) -> MUST NOT forward!
        net.addPhysicalLink("iPhone-B", "iPhone-D")
        let nodeD = try #require(net.node("iPhone-D"))
        #expect(nodeD.router.dtnOutbox.record(for: msgID, now: net.currentTime) == nil)
        #expect(nodeD.router.seenCache.contains(msgID, now: net.currentTime) == false)
        net.removePhysicalLink("iPhone-B", "iPhone-D")

        // 4. Direct Target Encounter: B meets C -> delivers immediately despite remainingCopies == 1!
        net.addPhysicalLink("iPhone-B", "iPhone-C")
        let nodeC = try #require(net.node("iPhone-C"))
        #expect(nodeC.receivedMessages.count == 1)
        #expect(nodeC.receivedMessages.first?.id == msgID)
        #expect(nodeC.receivedMessages.first?.text == "Gói tin Spray-and-Wait L=4")
        #expect(nodeC.receivedMessages.first?.hopCount == 2)
    }

    // MARK: - Scenario 5: Epidemic Store-and-Forward (SummaryVector + PacketRequest)

    @Test("Scenario 5: Epidemic Store-and-Forward carries offline DTN message A -> B -> C via SummaryVector + PacketRequest")
    func epidemicStoreAndForwardDataMule() throws {
        var net = SimulatedMeshNetwork(
            nodeSpecs: [
                ("iPhone-A", "iPhone-A", "seed-a"),
                ("iPhone-B", "iPhone-B", "seed-b"),
                ("iPhone-C", "iPhone-C", "seed-c"),
            ],
            initialLinks: [],
            routingStrategy: .epidemic
        )

        // 1. C (and B) completely offline -> A sends to C -> queued in DTNOutbox (.queuedDTN)
        let msgID = try net.sendChat(
            from: "iPhone-A",
            to: "iPhone-C",
            text: "Tin nhắn mang qua Data Mule B"
        )

        let initialA = try #require(net.node("iPhone-A"))
        #expect(initialA.deliveryStates[msgID] == .queuedDTN)
        #expect(initialA.router.dtnOutbox.summaryVector(now: net.currentTime) == [msgID])

        // 2. B meets A -> reconciles SummaryVector + PacketRequest and stores packet in B's DTNOutbox
        net.addPhysicalLink("iPhone-A", "iPhone-B")
        let syncedB = try #require(net.node("iPhone-B"))
        #expect(syncedB.packetLogs.contains { $0.packetType == .summaryVector && $0.direction == .rx })
        #expect(syncedB.packetLogs.contains { $0.packetType == .packetRequest && $0.direction == .tx })
        #expect(syncedB.router.dtnOutbox.summaryVector(now: net.currentTime).contains(msgID))

        // 3. B disconnects from A and walks over to C -> C receives message via Epidemic sync and emits ACK
        net.removePhysicalLink("iPhone-A", "iPhone-B")
        net.addPhysicalLink("iPhone-B", "iPhone-C")

        let syncedC = try #require(net.node("iPhone-C"))
        #expect(syncedC.packetLogs.contains { $0.packetType == .packetRequest && $0.direction == .tx })
        #expect(syncedC.receivedMessages.count == 1)
        let delivered = try #require(syncedC.receivedMessages.first)
        #expect(delivered.id == msgID)
        #expect(delivered.text == "Tin nhắn mang qua Data Mule B")
        #expect(delivered.hopCount == 2)
        #expect(syncedC.packetLogs.contains { $0.packetType == .ack && $0.direction == .tx })

        // 4. Bonus DTN Antipacket return: when B walks back to A, even the ACK syncs back so A hits .deliveredAck!
        net.removePhysicalLink("iPhone-B", "iPhone-C")
        net.addPhysicalLink("iPhone-B", "iPhone-A")
        let finalA = try #require(net.node("iPhone-A"))
        #expect(finalA.deliveryStates[msgID] == .deliveredAck)
        #expect(finalA.router.dtnOutbox.count == 0)
    }

    // MARK: - Scenario 6: Multi-Hop Ping / Pong RTT & Hop Count

    @Test("Scenario 6: Multi-hop Ping / Pong A -> B -> C -> B -> A records positive RTT and hops == 2")
    func multiHopPingPongRTTAndHops() throws {
        var net = SimulatedMeshNetwork(hopLatency: 0.012)
        net.setSymmetricBlock("iPhone-A", "iPhone-C", isBlocked: true)

        _ = try net.sendPing(from: "iPhone-A", to: "iPhone-C")

        let nodeA = try #require(net.node("iPhone-A"))
        let completed = try #require(nodeA.completedPings.first)
        #expect(completed.peerID == "iPhone-C")
        #expect(completed.hops == 2)
        #expect(completed.rttMs == 48) // 4 hops total (A->B->C->B->A) * 12ms = 48ms > 0
        #expect(nodeA.router.telemetry.averageRTTMs == 48)

        let peerSummaryC = try #require(nodeA.router.knownPeers.first { $0.id == "iPhone-C" })
        #expect(peerSummaryC.lastRTTMilliseconds == 48)
        #expect(
            peerSummaryC.linkKind
                == .relayedMesh(viaNodeID: "iPhone-B", viaDisplayName: "iPhone-B", hops: 2)
        )
    }

    // MARK: - DTNOutbox Capacity & Mock Mode Auto-Reply Sanity

    @Test("DTNOutbox evicts oldest record past capacity, prunes expired entries, and sorts newest first")
    func dtnOutboxEvictionAndSorting() {
        var outbox = DTNOutbox(capacity: 2)
        let t0 = Date(timeIntervalSince1970: 1_730_000_000)

        let p1 = MeshPacket(type: .chat, senderID: "a", senderName: "A", targetID: "c", timestamp: t0)
        let p2 = MeshPacket(type: .chat, senderID: "a", senderName: "A", targetID: "c", timestamp: t0.addingTimeInterval(5))
        let p3 = MeshPacket(type: .chat, senderID: "a", senderName: "A", targetID: "c", timestamp: t0.addingTimeInterval(10))

        outbox.enqueue(p1, now: t0, lifetime: 100)
        outbox.enqueue(p2, now: t0.addingTimeInterval(5), lifetime: 100)
        #expect(outbox.allRecords(now: t0.addingTimeInterval(6)).map(\.id) == [p2.id, p1.id])

        // Exceeding capacity=2 evicts oldest (p1)
        outbox.enqueue(p3, now: t0.addingTimeInterval(10), lifetime: 100)
        #expect(outbox.summaryVector(now: t0.addingTimeInterval(10)) == [p2.id, p3.id])

        // Expiration pruning
        outbox.pruneExpired(now: t0.addingTimeInterval(106))
        #expect(outbox.summaryVector(now: t0.addingTimeInterval(106)) == [p3.id])
        #expect(outbox.markDelivered(packetID: p3.id) == true)
        #expect(outbox.count == 0)
    }

    // MARK: - Review Regression Tests (Failed E2EE ACK Suppression & TOFU Key Pinning)

    @Test("Regression: Tampered 1-byte E2EE chat reaching recipient C emits zero ACKs and stays undelivered")
    func tamperedE2EEChatSuppressesAckAndDelivery() throws {
        var net = SimulatedMeshNetwork()
        let msgID = try net.sendChat(
            from: "iPhone-A",
            to: "iPhone-C",
            text: "Nội dung nguyên vẹn không được mất dữ liệu",
            settle: false
        )

        let wireFrame = try #require(net.pendingWireFrames.first { $0.packet.id == msgID })
        var corruptedPacket = wireFrame.packet
        var mutatedPayload = corruptedPacket.payload
        mutatedPayload[mutatedPayload.count / 2] ^= 0x01
        corruptedPacket = MeshPacket(
            id: corruptedPacket.id,
            type: corruptedPacket.type,
            senderID: corruptedPacket.senderID,
            senderName: corruptedPacket.senderName,
            targetID: corruptedPacket.targetID,
            routePath: corruptedPacket.routePath,
            routeNames: corruptedPacket.routeNames,
            ttl: corruptedPacket.ttl,
            remainingCopies: corruptedPacket.remainingCopies,
            timestamp: corruptedPacket.timestamp,
            isEncrypted: corruptedPacket.isEncrypted,
            senderPublicKeyBase64: corruptedPacket.senderPublicKeyBase64,
            payload: mutatedPayload
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let corruptedWireData = try encoder.encode(corruptedPacket)

        // Deliver corrupted wire packet to C instead of the original frame
        var routerC = try #require(net.node("iPhone-C")).router
        let sealerC = try #require(net.node("iPhone-C")).sealer
        let effectsOnC = routerC.handleIncoming(
            rawData: corruptedWireData,
            fromDirectPeerID: "iPhone-A",
            sealer: sealerC,
            now: net.currentTime
        )

        let receivedMessages = effectsOnC.compactMap { effect -> ReceivedMeshMessage? in
            if case let .messageReceived(msg) = effect { return msg }
            return nil
        }
        let emittedTransmissions = effectsOnC.compactMap { effect -> MeshPacket? in
            if case let .transmit(_, pkt, _) = effect { return pkt }
            return nil
        }

        #expect(receivedMessages.isEmpty)
        #expect(emittedTransmissions.contains { $0.type == .ack } == false)
        // Origin A still retains the undelivered message in its DTNOutbox
        #expect(net.node("iPhone-A")?.router.dtnOutbox.record(for: msgID, now: net.currentTime) != nil)
    }

    @Test("Regression: Unseeded recipient C decrypts E2EE chat via senderPublicKeyBase64 (TOFU) and rejects spoofed key")
    func tofuSenderPublicKeyDecryptionAndSpoofRejection() throws {
        let now = Date(timeIntervalSince1970: 1_730_400_000)
        let sealerA = SimulatedEnvelopeSealer(seed: "standalone-a")
        let sealerB = SimulatedEnvelopeSealer(seed: "standalone-b")
        let sealerC = SimulatedEnvelopeSealer(seed: "standalone-c")

        let identityA = NodeIdentity(nodeID: "node-a", displayName: "Alpha", publicKeyBase64: sealerA.publicKeyBase64)
        let identityB = NodeIdentity(nodeID: "node-b", displayName: "Bravo", publicKeyBase64: sealerB.publicKeyBase64)
        let identityC = NodeIdentity(nodeID: "node-c", displayName: "Charlie", publicKeyBase64: sealerC.publicKeyBase64)

        var routerA = MeshRouter(localIdentity: identityA)
        var routerB = MeshRouter(localIdentity: identityB)
        var routerC = MeshRouter(localIdentity: identityC)

        // Linear 3-hop / 2-hop chain A — B — C WITHOUT pre-registering A's key on C!
        _ = routerA.updateDirectPeers([identityB], now: now)
        _ = routerB.updateDirectPeers([identityA, identityC], now: now)
        _ = routerC.updateDirectPeers([identityB], now: now)
        #expect(routerC.knownPeers.contains { $0.id == "node-a" } == false)

        // Only A knows C's public key (e.g. scanned QR earlier); C has NEVER seen A
        let (msgID, txEffectsA) = try routerA.sendChat(
            text: "Tin nhắn E2EE xuyên trạm lần đầu (TOFU)",
            to: "node-c",
            sealer: sealerA,
            recipientPublicKeyBase64: sealerC.publicKeyBase64,
            now: now
        )

        let wireAtoB = try #require(
            txEffectsA.compactMap { effect -> Data? in
                if case let .transmit(data, pkt, _) = effect, pkt.id == msgID { return data }
                return nil
            }.first
        )

        let relayEffectsB = routerB.handleIncoming(
            rawData: wireAtoB,
            fromDirectPeerID: "node-a",
            sealer: sealerB,
            now: now.addingTimeInterval(0.012)
        )
        let wireBtoC = try #require(
            relayEffectsB.compactMap { effect -> Data? in
                if case let .transmit(data, pkt, _) = effect, pkt.id == msgID { return data }
                return nil
            }.first
        )

        let rxEffectsC = routerC.handleIncoming(
            rawData: wireBtoC,
            fromDirectPeerID: "node-b",
            sealer: sealerC,
            now: now.addingTimeInterval(0.024)
        )

        let delivered = try #require(
            rxEffectsC.compactMap { effect -> ReceivedMeshMessage? in
                if case let .messageReceived(msg) = effect { return msg }
                return nil
            }.first
        )
        #expect(delivered.id == msgID)
        #expect(delivered.text == "Tin nhắn E2EE xuyên trạm lần đầu (TOFU)")
        #expect(
            rxEffectsC.contains { effect in
                if case let .transmit(_, pkt, _) = effect { return pkt.type == .ack }
                return false
            }
        )

        // Verify TOFU pinned A's authentic key on C and rejects a spoofed packet claiming senderID == "node-a"
        let attackerSealer = SimulatedEnvelopeSealer(seed: "mallory-spoof")
        var attackerRouter = MeshRouter(
            localIdentity: NodeIdentity(
                nodeID: "node-a",
                displayName: "Alpha",
                publicKeyBase64: attackerSealer.publicKeyBase64
            )
        )
        _ = attackerRouter.updateDirectPeers([identityB], now: now)
        let (spoofID, spoofTx) = try attackerRouter.sendChat(
            text: "Tin giả mạo danh tính Alpha",
            to: "node-c",
            sealer: attackerSealer,
            recipientPublicKeyBase64: sealerC.publicKeyBase64,
            now: now.addingTimeInterval(1)
        )
        let spoofWire = try #require(
            spoofTx.compactMap { effect -> Data? in
                if case let .transmit(data, pkt, _) = effect, pkt.id == spoofID { return data }
                return nil
            }.first
        )

        let spoofEffectsOnC = routerC.handleIncoming(
            rawData: spoofWire,
            fromDirectPeerID: "node-b",
            sealer: sealerC,
            now: now.addingTimeInterval(1.012)
        )
        #expect(
            spoofEffectsOnC.contains { effect in
                if case .messageReceived = effect { return true }
                if case let .transmit(_, pkt, _) = effect, pkt.type == .ack { return true }
                return false
            } == false
        )

        // Also exercise Phase 2/3 public profile & telemetry hooks
        let profileEffects = routerC.updateLocalProfile(displayName: "Charlie-Pro", now: now.addingTimeInterval(2))
        #expect(routerC.localIdentity.displayName == "Charlie-Pro")
        #expect(profileEffects.contains { if case let .transmit(_, pkt, _) = $0 { return pkt.type == .heartbeat }; return false })
        routerC.resetTelemetry()
        #expect(routerC.telemetry == TelemetrySnapshot())

        var sim = SimulatedMeshNetwork()
        sim.updateNodeDisplayName("Trạm-A", for: SimulatedMeshNetwork.nodeAID)
        #expect(sim.node(SimulatedMeshNetwork.nodeAID)?.identity.displayName == "Trạm-A")
        sim.resetTelemetry()
        #expect(sim.node(SimulatedMeshNetwork.nodeAID)?.router.telemetry == TelemetrySnapshot())
        #expect(sim.node(SimulatedMeshNetwork.nodeAID)?.packetLogs.isEmpty == true)
    }
}
