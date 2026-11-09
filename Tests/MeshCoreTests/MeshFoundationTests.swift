import Foundation
import MeshCore
import Testing

@Suite("MeshCore Foundation Models & BoundedSeenCache")
struct MeshFoundationTests {
    // MARK: - JSON Round-Trip Tests

    @Test("MeshPacket and all protocol payloads round-trip cleanly through JSON")
    func packetAndPayloadsJSONRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        let coord = GeoCoordinate(latitude: 10.776889, longitude: 106.700806, accuracyMeters: 4.5)
        let chatPayload = ChatMessagePayload(text: "SOS trạm bắc cầu cần hỗ trợ", coordinate: coord)
        let chatPayloadBytes = try encoder.encode(chatPayload)
        let decodedChat = try decoder.decode(ChatMessagePayload.self, from: chatPayloadBytes)
        #expect(decodedChat == chatPayload)

        let textOnlyChat = ChatMessagePayload(text: "Xin chào mạng lưới ngoại tuyến")
        #expect(try decoder.decode(ChatMessagePayload.self, from: encoder.encode(textOnlyChat)) == textOnlyChat)

        let peerA = NodeIdentity(
            nodeID: "node-alpha",
            displayName: "Alpha",
            publicKeyBase64: Data("alpha-curve25519-pub".utf8).base64EncodedString()
        )
        let peerB = NodeIdentity(
            nodeID: "node-bravo",
            displayName: "Bravo",
            publicKeyBase64: Data("bravo-curve25519-pub".utf8).base64EncodedString()
        )

        let heartbeat = HeartbeatPayload(identity: peerA, directPeers: [peerB])
        #expect(try decoder.decode(HeartbeatPayload.self, from: encoder.encode(heartbeat)) == heartbeat)

        let ping = PingPayload(
            probeID: try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555")),
            originTimestampMs: 1_730_300_000_123
        )
        #expect(try decoder.decode(PingPayload.self, from: encoder.encode(ping)) == ping)

        let ack = AckPayload(
            acknowledgedPacketID: try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        )
        #expect(try decoder.decode(AckPayload.self, from: encoder.encode(ack)) == ack)

        let id1 = UUID()
        let id2 = UUID()
        let summaryVector = SummaryVectorPayload(heldPacketIDs: [id1, id2])
        #expect(try decoder.decode(SummaryVectorPayload.self, from: encoder.encode(summaryVector)) == summaryVector)

        let packetRequest = PacketRequestPayload(missingPacketIDs: [id2])
        #expect(try decoder.decode(PacketRequestPayload.self, from: encoder.encode(packetRequest)) == packetRequest)

        let fixedTimestamp = Date(timeIntervalSince1970: 1_730_300_000.250)
        let broadcastPacket = MeshPacket(
            id: id1,
            type: .sos,
            senderID: peerA.nodeID,
            senderName: peerA.displayName,
            targetID: MeshPacket.broadcastTarget,
            routePath: [peerA.nodeID, peerB.nodeID],
            routeNames: [peerA.displayName, peerB.displayName],
            ttl: 6,
            remainingCopies: 4,
            timestamp: fixedTimestamp,
            isEncrypted: false,
            payload: chatPayloadBytes
        )

        let packetJSON = try encoder.encode(broadcastPacket)
        let decodedPacket = try decoder.decode(MeshPacket.self, from: packetJSON)
        #expect(decodedPacket == broadcastPacket)
        #expect(decodedPacket.isBroadcast)
        #expect(decodedPacket.hopCount == 2)
        #expect(MeshPacket.serviceType == "meshpulse")

        // Also verify default Foundation JSONEncoder/JSONDecoder compatibility
        let stdPacket = try JSONDecoder().decode(MeshPacket.self, from: JSONEncoder().encode(broadcastPacket))
        #expect(stdPacket == broadcastPacket)
        #expect(MeshPacket(type: .chat, senderID: "n1", senderName: "N1", targetID: "n2").hopCount == 1)
        #expect(!MeshPacket(type: .chat, senderID: "n1", senderName: "N1", targetID: "n2").isBroadcast)
    }

    @Test("RoutingStrategy, LinkKind, DeliveryState, PeerSummary, and TelemetrySnapshot semantics")
    func supportingDomainModels() throws {
        #expect(PacketType.allCases.count == 12)
        #expect(RoutingStrategy.allCases.count == 3)
        for strategy in RoutingStrategy.allCases {
            #expect(strategy.id == strategy.rawValue)
            #expect(!strategy.title.isEmpty)
            #expect(!strategy.subtitle.isEmpty)
        }

        let links: [LinkKind] = [
            .directP2P,
            .relayedMesh(viaNodeID: "relay-1", viaDisplayName: "Trạm B", hops: 2),
            .offlineDTN,
        ]
        for link in links {
            let decoded = try JSONDecoder().decode(LinkKind.self, from: JSONEncoder().encode(link))
            #expect(decoded == link)
        }

        let states: [DeliveryState] = [.queuedDTN, .sentDirect, .relayed, .deliveredAck]
        for state in states {
            let decoded = try JSONDecoder().decode(DeliveryState.self, from: JSONEncoder().encode(state))
            #expect(decoded == state)
        }

        let node = NodeIdentity(nodeID: "node-charlie", displayName: "Charlie")
        let summary = PeerSummary(
            identity: node,
            linkKind: .directP2P,
            lastRTTMilliseconds: 18,
            lastSeen: Date(timeIntervalSince1970: 1_730_300_500)
        )
        #expect(summary.id == "node-charlie")

        var telemetry = TelemetrySnapshot()
        #expect(telemetry.averageRTTMs == nil)
        telemetry.recordRTT(10, maxSamples: 3)
        telemetry.recordRTT(20, maxSamples: 3)
        telemetry.recordRTT(30, maxSamples: 3)
        telemetry.recordRTT(40, maxSamples: 3)
        #expect(telemetry.rttSamplesMs == [20, 30, 40])
        #expect(telemetry.averageRTTMs == 30)
    }

    // MARK: - NodeIdentity Public Key Fingerprint Tests

    @Test("NodeIdentity.publicKeyFingerprint is deterministic, unique per key, and nil on invalid input")
    func nodeIdentityPublicKeyFingerprint() throws {
        // NIST SHA-256("abc") starts with ba7816bf 8f01cfea -> "BA78-16BF-8F01-CFEA"
        let abcIdentity1 = NodeIdentity(
            nodeID: "n1",
            displayName: "Node 1",
            publicKeyBase64: Data("abc".utf8).base64EncodedString()
        )
        let abcIdentity2 = NodeIdentity(
            nodeID: "n2",
            displayName: "Node 2",
            publicKeyBase64: Data("abc".utf8).base64EncodedString()
        )
        let fingerprint1 = try #require(abcIdentity1.publicKeyFingerprint)
        let fingerprint2 = try #require(abcIdentity2.publicKeyFingerprint)
        #expect(fingerprint1 == "BA78-16BF-8F01-CFEA")
        #expect(fingerprint1 == fingerprint2)
        #expect(fingerprint1.count == 19)

        let otherKeyIdentity = NodeIdentity(
            nodeID: "n3",
            displayName: "Node 3",
            publicKeyBase64: Data("different-curve25519-public-key-32b".utf8).base64EncodedString()
        )
        let otherFingerprint = try #require(otherKeyIdentity.publicKeyFingerprint)
        #expect(otherFingerprint != fingerprint1)
        #expect(otherFingerprint.split(separator: "-").map(\.count) == [4, 4, 4, 4])

        // Invalid / missing cases must return nil
        #expect(NodeIdentity(nodeID: "nil", displayName: "Nil", publicKeyBase64: nil).publicKeyFingerprint == nil)
        #expect(NodeIdentity(nodeID: "empty", displayName: "Empty", publicKeyBase64: "").publicKeyFingerprint == nil)
        #expect(
            NodeIdentity(nodeID: "bad", displayName: "Bad", publicKeyBase64: "%%%not-valid-base64%%%")
                .publicKeyFingerprint == nil
        )
    }

    // MARK: - BoundedSeenCache Tests

    @Test("BoundedSeenCache rejects duplicates within maxAge and evicts oldest entry past capacity")
    func boundedSeenCacheDuplicateAndCapacityEviction() {
        var cache = BoundedSeenCache(capacity: 3, maxAge: 600)
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let idD = UUID()

        #expect(cache.insertIfNew(idA, now: t0) == true)
        #expect(cache.contains(idA, now: t0.addingTimeInterval(599)) == true)
        // Duplicate within maxAge must be rejected without evicting other slots
        #expect(cache.insertIfNew(idA, now: t0.addingTimeInterval(30)) == false)
        #expect(cache.activeCount == 1)

        #expect(cache.insertIfNew(idB, now: t0.addingTimeInterval(1)) == true)
        #expect(cache.insertIfNew(idC, now: t0.addingTimeInterval(2)) == true)
        #expect(cache.activeCount == 3)

        // Inserting a 4th distinct ID exceeds capacity=3 and evicts oldest (idA)
        #expect(cache.insertIfNew(idD, now: t0.addingTimeInterval(3)) == true)
        #expect(cache.activeCount == 3)
        #expect(cache.contains(idA, now: t0.addingTimeInterval(3)) == false)
        #expect(cache.contains(idB, now: t0.addingTimeInterval(3)) == true)
        #expect(cache.contains(idC, now: t0.addingTimeInterval(3)) == true)
        #expect(cache.contains(idD, now: t0.addingTimeInterval(3)) == true)
    }

    @Test("BoundedSeenCache re-accepts expired UUID and preserves new generation across ring wrap-around")
    func boundedSeenCacheExpiredReinsertionWithoutRingSlotCorruption() {
        var cache = BoundedSeenCache(capacity: 3, maxAge: 600)
        let t0 = Date(timeIntervalSince1970: 2_000_000)

        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let idD = UUID()
        let idE = UUID()

        // Slot 0: (idA, gen 1) at t=0; Slot 1: (idB, gen 2) at t=10
        #expect(cache.insertIfNew(idA, now: t0) == true)
        #expect(cache.insertIfNew(idB, now: t0.addingTimeInterval(10)) == true)

        // At t=700 (> maxAge=600), idA is expired
        let t700 = t0.addingTimeInterval(700)
        #expect(cache.contains(idA, now: t700) == false)

        // Re-insert idA at t=700 -> goes into Slot 2 with gen 3; writeIndex wraps to 0
        #expect(cache.insertIfNew(idA, now: t700) == true)
        #expect(cache.contains(idA, now: t700) == true)

        // Fill ring so old Slot 0 (stale idA, gen 1) and Slot 1 (stale idB, gen 2) are overwritten!
        let t701 = t0.addingTimeInterval(701)
        let t702 = t0.addingTimeInterval(702)
        #expect(cache.insertIfNew(idC, now: t701) == true) // Overwrites Slot 0 (old idA gen 1)
        #expect(cache.insertIfNew(idD, now: t702) == true) // Overwrites Slot 1 (old idB gen 2)

        // Critical invariant: new idA (Slot 2, gen 3) MUST still be alive and reject duplicates!
        #expect(cache.contains(idA, now: t702) == true)
        #expect(cache.insertIfNew(idA, now: t702) == false)
        #expect(cache.activeCount == 3)
        #expect(cache.activeCount(now: t702) == 3)

        // Only when a 3rd newer item (idE) wraps onto Slot 2 should idA (gen 3) be evicted
        let t703 = t0.addingTimeInterval(703)
        #expect(cache.insertIfNew(idE, now: t703) == true)
        #expect(cache.contains(idA, now: t703) == false)

        cache.reset()
        #expect(cache.activeCount == 0)
        #expect(cache.contains(idE, now: t703) == false)
    }

    // MARK: - Next-Gen Roadmap Module Tests (Modules 1–6)

    @Test("Module 1: Out-of-Band QR verification URI round-trip and TOFU MITM Key Conflict detection")
    func qrVerificationURIAndTOFUMITMDetection() throws {
        let sealerA = SimulatedEnvelopeSealer(seed: "node-a")
        let sealerB = SimulatedEnvelopeSealer(seed: "node-b")
        let attackerSealer = SimulatedEnvelopeSealer(seed: "attacker-mitm")

        let nodeA = NodeIdentity(nodeID: "iPhone-A", displayName: "iPhone-A", publicKeyBase64: sealerA.publicKeyBase64)
        let nodeB = NodeIdentity(nodeID: "iPhone-B", displayName: "iPhone-B", publicKeyBase64: sealerB.publicKeyBase64)

        let uri = nodeB.verificationURIString
        #expect(uri.hasPrefix("meshpulse://verify?"))
        let parsed = try #require(NodeIdentity.parseVerificationURI(uri))
        #expect(parsed.nodeID == "iPhone-B")
        #expect(parsed.fingerprint == nodeB.publicKeyFingerprint)
        #expect(parsed.publicKeyBase64 == sealerB.publicKeyBase64)

        var routerA = MeshRouter(localIdentity: nodeA)
        _ = routerA.updateDirectPeers([nodeB])
        #expect(routerA.knownPeers.first?.trustState == .unverifiedTOFU)

        // Attacker spoofs iPhone-B with a different public key -> router flags .keyConflict and preserves original pinned key!
        let spoofedB = NodeIdentity(nodeID: "iPhone-B", displayName: "iPhone-B", publicKeyBase64: attackerSealer.publicKeyBase64)
        let conflictEffects = routerA.updateDirectPeers([spoofedB])
        let detectedConflict = conflictEffects.contains { effect in
            if case let .securityKeyConflictDetected(peerID, _, pinned, conflicting) = effect {
                return peerID == "iPhone-B"
                    && pinned == sealerB.publicKeyBase64
                    && conflicting == attackerSealer.publicKeyBase64
            }
            return false
        }
        #expect(detectedConflict == true)
        #expect(routerA.knownPeers.first?.trustState == .keyConflict)
        #expect(routerA.knownPeers.first?.identity.publicKeyBase64 == sealerB.publicKeyBase64)

        // Verify authentic peer via QR -> upgrades to .verifiedOutOfBand and clears conflict
        let verified = routerA.verifyPeerOutOfBand(
            nodeID: parsed.nodeID,
            fingerprint: parsed.fingerprint,
            publicKeyBase64: parsed.publicKeyBase64
        )
        #expect(verified == true)
        #expect(routerA.knownPeers.first?.trustState == .verifiedOutOfBand)
        #expect(routerA.knownPeers.first?.conflictPublicKeyBase64 == nil)
    }

    @Test("Module 2 & 3: Multi-hop 16KB chunked media transfer and voice note with offline transcript + ACK")
    func multiHopMediaChunkingAndVoiceNoteRouting() throws {
        var net = SimulatedMeshNetwork(autoReplyEnabled: false)
        // Force 2-hop relay path iPhone-A -> iPhone-B -> iPhone-C
        net.setSymmetricBlock("iPhone-A", "iPhone-C", isBlocked: true)

        // Create a 40 KB synthetic compressed image (splits into 3 chunks of 16KB, 16KB, 8KB)
        let originalImageBytes = Data((0..<40_000).map { UInt8($0 & 0xFF) })
        let chunks = MeshChunker.split(data: originalImageBytes, caption: "Bản đồ địa hình khu vực B")
        #expect(chunks.count == 3)
        #expect(chunks[0].chunkData.count == 16_384)
        #expect(chunks[1].chunkData.count == 16_384)
        #expect(chunks[2].chunkData.count == 7_232)

        let (transferID, packetIDs) = try net.sendMediaChunks(
            from: "iPhone-A",
            to: "iPhone-C",
            data: originalImageBytes,
            caption: "Bản đồ địa hình khu vực B"
        )
        #expect(packetIDs.count == 3)

        let nodeA = try #require(net.node("iPhone-A"))
        let nodeC = try #require(net.node("iPhone-C"))

        let assembledProgress = try #require(nodeC.mediaTransfers[transferID])
        #expect(assembledProgress.isCompleted == true)
        #expect(assembledProgress.receivedChunks == 3)
        #expect(assembledProgress.totalChunks == 3)
        #expect(assembledProgress.assembledData == originalImageBytes)
        #expect(assembledProgress.hopCount == 2)

        // End-to-End ACK from iPhone-C back to iPhone-A marks transferID as deliveredAck
        #expect(nodeA.deliveryStates[transferID] == .deliveredAck)

        // Voice note with offline transcript across 2-hop mesh
        let voicePayload = VoiceNotePayload(
            audioData: Data(repeating: 0x42, count: 9_600),
            durationSeconds: 4.8,
            transcriptText: "Đội tiền trạm đã tới điểm tập kết an toàn.",
            waveformSamples: [0.2, 0.5, 0.9, 0.4, 0.7]
        )
        let voiceID = try net.sendVoiceNote(
            from: "iPhone-A",
            to: "iPhone-C",
            voiceNote: voicePayload
        )
        let updatedNodeC = try #require(net.node("iPhone-C"))
        let receivedVoice = try #require(updatedNodeC.receivedMessages.first { $0.id == voiceID })
        #expect(receivedVoice.packetType == .voiceNote)
        #expect(receivedVoice.voiceNote == voicePayload)
        #expect(receivedVoice.hopCount == 2)
    }

    @Test("Module 4 & 5: Offline GPS ProximityMath and CRDT SafetyRollCall + MeshPoll convergence")
    func proximityMathAndCRDTConvergence() throws {
        let origin = SimulatedMeshNetwork.defaultSimulatedCoordinate(for: "iPhone-A")
        let targetB = SimulatedMeshNetwork.defaultSimulatedCoordinate(for: "iPhone-B")

        let distMeters = ProximityMath.haversineDistanceMeters(from: origin, to: targetB)
        #expect(distMeters > 35 && distMeters < 50)
        let bearing = ProximityMath.bearingDegrees(from: origin, to: targetB)
        #expect(bearing > 30 && bearing < 60)
        #expect(ProximityMath.cardinalDirectionVN(forBearing: bearing) == "Đông Bắc")
        #expect(ProximityMath.relativeArrowAngleDegrees(bearing: 45, deviceHeading: 45) == 0)

        // CRDT SafetyRollCall & MeshPoll multi-node convergence in SimulatedMeshNetwork
        var net = SimulatedMeshNetwork(autoReplyEnabled: true)
        net.setSymmetricBlock("iPhone-A", "iPhone-C", isBlocked: true)

        var rollCall = SafetyRollCallState(
            title: "Điểm danh sau mưa lớn",
            createdByNodeID: "iPhone-A",
            createdByName: "iPhone-A"
        )
        rollCall.recordVote(nodeID: "iPhone-A", displayName: "iPhone-A", status: .safe)
        _ = try net.broadcastRollCall(from: "iPhone-A", rollCall: rollCall)

        let convergedRC = try #require(net.node("iPhone-A")?.router.activeRollCall)
        #expect(convergedRC.responses.count == 3)
        #expect(convergedRC.safeCount == 3)

        var poll = MeshPollState(
            question: "Dừng nghỉ ở trạm tiếp theo?",
            options: ["Dừng nghỉ 15 phút", "Đi tiếp tới trạm chính"],
            createdByNodeID: "iPhone-A",
            createdByName: "iPhone-A"
        )
        poll.castVote(nodeID: "iPhone-A", displayName: "iPhone-A", optionIndex: 0)
        _ = try net.broadcastPoll(from: "iPhone-A", poll: poll)

        let convergedPoll = try #require(net.node("iPhone-A")?.router.activePoll)
        #expect(convergedPoll.totalVotes == 3)
        #expect(convergedPoll.voteCount(forOption: 0) == 2)
        #expect(convergedPoll.voteCount(forOption: 1) == 1)
    }
}
