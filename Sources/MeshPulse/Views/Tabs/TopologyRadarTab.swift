#if canImport(SwiftUI)
import MeshCore
import SwiftUI

/// Tab 1 (`Mạng lưới`): Real-time multi-hop topology graph rendered on `SwiftUI Canvas`
/// paired with actionable nearby/relayed station cards (`Ping` RTT & quick 1-to-1 E2EE jump).
public struct TopologyRadarTab: View {
    public var coordinator: MeshCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pingFeedbackCount = 0

    public init(coordinator: MeshCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                radarCanvasCard
                peerStationsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(MeshTheme.background)
        .sensoryFeedback(.impact(weight: .light), trigger: pingFeedbackCount)
    }

    // MARK: - Real-Time Canvas Topology Card

    private var radarCanvasCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Label("Đồ thị Định tuyến Thời gian thực", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MeshTheme.primaryText)

                Spacer(minLength: 4)

                Text(coordinator.routingStrategy.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MeshTheme.badgeText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(MeshTheme.elevatedSurface, in: Capsule())
            }

            TimelineView(
                .animation(
                    minimumInterval: 1.0 / 60.0,
                    paused: coordinator.activePulses.isEmpty || reduceMotion || !coordinator.isRadioEnabled
                )
            ) { timeline in
                Canvas { context, size in
                    drawRadarBackdrop(in: &context, size: size)
                    let positions = computeNodePositions(in: size)

                    if coordinator.isRadioEnabled {
                        drawTopologyEdges(in: &context, positions: positions)
                        if !reduceMotion {
                            drawActivePulses(in: &context, at: timeline.date, positions: positions)
                        }
                        drawPeerNodes(in: &context, positions: positions)
                    }

                    drawLocalCenterNode(in: &context, at: positions[coordinator.localIdentity.nodeID] ?? CGPoint(x: size.width / 2, y: size.height / 2))
                }
                .frame(maxWidth: .infinity, minHeight: 240)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(radarAccessibilitySummary)
            }

            legendBar
        }
        .padding(14)
        .meshCard()
    }

    private var legendBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Capsule()
                    .fill(MeshTheme.p2pGreen)
                    .frame(width: 14, height: 3.5)
                Text("1-Hop P2P")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(MeshTheme.secondaryText)
            }

            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    Capsule().fill(MeshTheme.meshAmber).frame(width: 5, height: 3.5)
                    Capsule().fill(MeshTheme.meshAmber).frame(width: 5, height: 3.5)
                }
                Text("Bắc cầu Multi-Hop")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(MeshTheme.secondaryText)
            }

            Spacer(minLength: 4)

            HStack(spacing: 5) {
                Circle()
                    .fill(MeshTheme.dtnIndigo)
                    .frame(width: 6, height: 6)
                Text("DTN: \(coordinator.dtnRecords.count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(MeshTheme.secondaryText)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Canvas Drawing Primitives

    private func drawRadarBackdrop(in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxR = min(size.width, size.height) * 0.44

        for fraction in [0.46, 0.86] {
            let r = maxR * fraction
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            let ring = Path(ellipseIn: rect)
            context.stroke(
                ring,
                with: .color(Color.white.opacity(0.06)),
                style: StrokeStyle(lineWidth: 1, dash: [4, 6])
            )
        }
    }

    private func computeNodePositions(in size: CGSize) -> [String: CGPoint] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var positions: [String: CGPoint] = [
            coordinator.localIdentity.nodeID: center
        ]
        guard coordinator.isRadioEnabled else { return positions }

        let visiblePeers = coordinator.peers
        var directPeers: [PeerSummary] = []
        var relayedByVia: [String: [PeerSummary]] = [:]
        var offlinePeers: [PeerSummary] = []

        for peer in visiblePeers {
            switch peer.linkKind {
            case .directP2P:
                directPeers.append(peer)
            case let .relayedMesh(viaNodeID, _, _):
                relayedByVia[viaNodeID, default: []].append(peer)
            case .offlineDTN:
                offlinePeers.append(peer)
            }
        }

        let innerRx = max(58, min(size.width * 0.27, 108))
        let innerRy = max(48, min(size.height * 0.28, 76))
        let outerRx = max(92, min(size.width * 0.40, 158))
        let outerRy = max(72, min(size.height * 0.40, 102))

        var directAngles: [String: Double] = [:]
        let directStartAngle = -Double.pi * 0.72
        for (idx, peer) in directPeers.enumerated() {
            let step = (2.0 * Double.pi) / Double(max(1, directPeers.count))
            let angle = directStartAngle + Double(idx) * step
            directAngles[peer.id] = angle
            positions[peer.id] = clampedCanvasPoint(
                CGPoint(
                    x: center.x + CGFloat(cos(angle)) * innerRx,
                    y: center.y + CGFloat(sin(angle)) * innerRy
                ),
                in: size
            )
        }

        var unanchoredRelayed: [PeerSummary] = []
        for (viaID, children) in relayedByVia.sorted(by: { $0.key < $1.key }) {
            guard let baseAngle = directAngles[viaID] else {
                unanchoredRelayed.append(contentsOf: children)
                continue
            }
            for (idx, child) in children.enumerated() {
                let spread: Double
                if children.count == 1 {
                    spread = 0.72
                } else {
                    let centered = Double(idx) - Double(children.count - 1) / 2.0
                    spread = centered * 0.52 + 0.35
                }
                let angle = baseAngle + spread
                positions[child.id] = clampedCanvasPoint(
                    CGPoint(
                        x: center.x + CGFloat(cos(angle)) * outerRx,
                        y: center.y + CGFloat(sin(angle)) * outerRy
                    ),
                    in: size
                )
            }
        }

        let remainingOuter = unanchoredRelayed + offlinePeers
        let outerStartAngle = Double.pi * 0.22
        for (idx, peer) in remainingOuter.enumerated() {
            let step = (2.0 * Double.pi) / Double(max(1, remainingOuter.count))
            let angle = outerStartAngle + Double(idx) * step
            positions[peer.id] = clampedCanvasPoint(
                CGPoint(
                    x: center.x + CGFloat(cos(angle)) * outerRx,
                    y: center.y + CGFloat(sin(angle)) * outerRy
                ),
                in: size
            )
        }

        return positions
    }

    private func clampedCanvasPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let minX: CGFloat = 46
        let maxX = max(minX, size.width - 46)
        let minY: CGFloat = 24
        let maxY = max(minY, size.height - 34)
        return CGPoint(
            x: min(maxX, max(minX, point.x)),
            y: min(maxY, max(minY, point.y))
        )
    }

    private func drawTopologyEdges(
        in context: inout GraphicsContext,
        positions: [String: CGPoint]
    ) {
        for edge in coordinator.topologyEdges {
            guard let start = positions[edge.fromNodeID],
                  let end = positions[edge.toNodeID]
            else { continue }

            var path = Path()
            path.move(to: start)
            path.addLine(to: end)

            if edge.isDirectP2P {
                context.stroke(
                    path,
                    with: .color(MeshTheme.p2pGreen.opacity(0.85)),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
            } else {
                context.stroke(
                    path,
                    with: .color(MeshTheme.meshAmber.opacity(0.88)),
                    style: StrokeStyle(lineWidth: 2.0, lineCap: .round, dash: [6, 4])
                )
            }
        }
    }

    private func drawActivePulses(
        in context: inout GraphicsContext,
        at now: Date,
        positions: [String: CGPoint]
    ) {
        for pulse in coordinator.activePulses {
            let elapsed = now.timeIntervalSince(pulse.startedAt)
            guard elapsed >= 0, elapsed <= pulse.duration, pulse.duration > 0,
                  let fromPt = positions[pulse.fromNodeID],
                  let toPt = positions[pulse.toNodeID]
            else { continue }

            let t = CGFloat(elapsed / pulse.duration)
            let current = CGPoint(
                x: fromPt.x + (toPt.x - fromPt.x) * t,
                y: fromPt.y + (toPt.y - fromPt.y) * t
            )

            let color: Color =
                pulse.packetType == .sos
                ? MeshTheme.sosCrimson
                : (pulse.isDirectP2P ? MeshTheme.p2pGreen : MeshTheme.meshAmber)

            let haloRect = CGRect(x: current.x - 9, y: current.y - 9, width: 18, height: 18)
            context.fill(Path(ellipseIn: haloRect), with: .color(color.opacity(0.28)))

            let coreRect = CGRect(x: current.x - 4, y: current.y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: coreRect), with: .color(color))
        }
    }

    private func drawPeerNodes(
        in context: inout GraphicsContext,
        positions: [String: CGPoint]
    ) {
        for peer in coordinator.peers {
            guard let pt = positions[peer.id] else { continue }
            let accent = MeshTheme.color(for: peer.linkKind)
            let isOffline: Bool = {
                if case .offlineDTN = peer.linkKind { return true }
                return false
            }()

            let outerRect = CGRect(x: pt.x - 13, y: pt.y - 13, width: 26, height: 26)
            context.fill(Path(ellipseIn: outerRect), with: .color(MeshTheme.elevatedSurface))
            context.stroke(
                Path(ellipseIn: outerRect),
                with: .color(accent.opacity(isOffline ? 0.55 : 0.95)),
                style: StrokeStyle(lineWidth: 2, dash: isOffline ? [3, 3] : [])
            )

            let dotRect = CGRect(x: pt.x - 4.5, y: pt.y - 4.5, width: 9, height: 9)
            context.fill(Path(ellipseIn: dotRect), with: .color(accent))

            let label = context.resolve(
                Text(peer.identity.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isOffline ? MeshTheme.secondaryText : MeshTheme.primaryText)
            )
            context.draw(label, at: CGPoint(x: pt.x, y: pt.y + 17), anchor: .top)
        }
    }

    private func drawLocalCenterNode(in context: inout GraphicsContext, at pt: CGPoint) {
        let accent = coordinator.isRadioEnabled ? MeshTheme.p2pGreen : MeshTheme.sosCrimson
        let haloRect = CGRect(x: pt.x - 22, y: pt.y - 22, width: 44, height: 44)
        context.fill(Path(ellipseIn: haloRect), with: .color(accent.opacity(0.14)))

        let nodeRect = CGRect(x: pt.x - 15, y: pt.y - 15, width: 30, height: 30)
        context.fill(Path(ellipseIn: nodeRect), with: .color(MeshTheme.elevatedSurface))
        context.stroke(Path(ellipseIn: nodeRect), with: .color(accent), lineWidth: 2.2)

        let centerDot = CGRect(x: pt.x - 5.5, y: pt.y - 5.5, width: 11, height: 11)
        context.fill(Path(ellipseIn: centerDot), with: .color(accent))

        let title = context.resolve(
            Text("\(coordinator.localDisplayName) (Bạn)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(MeshTheme.primaryText)
        )
        context.draw(title, at: CGPoint(x: pt.x, y: pt.y + 19), anchor: .top)
    }

    private var radarAccessibilitySummary: String {
        guard coordinator.isRadioEnabled else {
            return "Đồ thị mạng lưới đang tạm dừng do sóng ngoại tuyến đang tắt."
        }
        return "Đồ thị mạng lưới gồm trạm trung tâm \(coordinator.localDisplayName), \(coordinator.directP2PCount) kết nối trực tiếp 1 bước nhảy và \(coordinator.meshRelayedCount) kết nối bắc cầu."
    }

    // MARK: - Nearby & Relayed Stations List

    private var peerStationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Danh sách Trạm trong Mạng")
                    .font(.headline)
                    .foregroundStyle(MeshTheme.primaryText)

                Spacer()

                Text("\(coordinator.isRadioEnabled ? coordinator.peers.count : 0) trạm")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(MeshTheme.secondaryText)
            }

            if !coordinator.isRadioEnabled {
                radioDisabledEmptyState
            } else if coordinator.peers.isEmpty {
                scanningEmptyState
            } else {
                ForEach(coordinator.peers) { peer in
                    peerStationCard(peer)
                }
            }
        }
    }

    private var radioDisabledEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.title2.weight(.semibold))
                .foregroundStyle(MeshTheme.sosCrimson)

            Text("Sóng ngoại tuyến đang tạm tắt")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MeshTheme.primaryText)

            Text("Bật lại sóng để tự động khám phá các thiết bị lân cận qua BLE / Wi-Fi Direct (AWDL) và xả hàng đợi DTN.")
                .font(.caption)
                .foregroundStyle(MeshTheme.secondaryText)
                .multilineTextAlignment(.center)

            Button {
                withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                    coordinator.toggleRadio()
                }
            } label: {
                Label("Bật sóng mạng lưới", systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MeshTheme.background)
                    .padding(.horizontal, 20)
                    .frame(minHeight: MeshTheme.minTapDimension)
                    .background(MeshTheme.p2pGreen, in: Capsule())
            }
            .buttonStyle(.applePressable)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .meshCard()
    }

    private var scanningEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title2.weight(.semibold))
                .foregroundStyle(MeshTheme.p2pGreen)

            Text("Đang quét các trạm MeshPulse xung quanh...")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MeshTheme.primaryText)

            Text("Mở MeshPulse trên thiết bị thứ hai hoặc bật Mock Mode trong tab Mesh Lab để mô phỏng mạng đa bước nhảy.")
                .font(.caption)
                .foregroundStyle(MeshTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .meshCard()
    }

    private func peerStationCard(_ peer: PeerSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                // Station Avatar
                ZStack {
                    Circle()
                        .fill(MeshTheme.elevatedSurface)
                        .frame(width: 40, height: 40)

                    Image(systemName: "iphone.gen3")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MeshTheme.color(for: peer.linkKind))

                    Circle()
                        .fill(MeshTheme.color(for: peer.linkKind))
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(MeshTheme.background, lineWidth: 1.5))
                        .offset(x: 14, y: 14)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(peer.identity.displayName)
                        .font(.headline)
                        .foregroundStyle(MeshTheme.primaryText)

                    Text(peer.identity.nodeID.prefix(12) + "…")
                        .font(.caption.monospaced())
                        .foregroundStyle(MeshTheme.secondaryText)
                }

                Spacer(minLength: 8)

                LinkStatusBadge(linkKind: peer.linkKind)
            }

            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    Image(systemName: "timer")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.secondaryText)
                    Text(peer.lastRTTMilliseconds.map { "\($0) ms" } ?? "-- ms")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(
                            peer.lastRTTMilliseconds != nil ? MeshTheme.primaryText : MeshTheme.secondaryText
                        )
                }

                if let fingerprint = peer.identity.publicKeyFingerprint {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield.fill")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.p2pGreen)
                        Text(String(fingerprint.prefix(9)))
                            .font(.caption2.monospaced())
                            .foregroundStyle(MeshTheme.secondaryText)
                    }
                }

                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    pingFeedbackCount += 1
                    coordinator.ping(peerID: peer.id)
                } label: {
                    Label("Ping", systemImage: "waveform.path.ecg")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MeshTheme.primaryText)
                        .frame(maxWidth: .infinity, minHeight: MeshTheme.minTapDimension)
                        .background(MeshTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(MeshTheme.hairlineBorder, lineWidth: 0.8)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.applePressable)
                .disabled(peer.linkKind == .offlineDTN)
                .opacity(peer.linkKind == .offlineDTN ? 0.5 : 1.0)
                .accessibilityLabel("Đo độ trễ Ping tới \(peer.identity.displayName)")

                Button {
                    withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                        coordinator.openDirectConversation(with: peer.id)
                    }
                } label: {
                    Label("Nhắn tin", systemImage: "bubble.left.and.lock.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MeshTheme.p2pGreen)
                        .frame(maxWidth: .infinity, minHeight: MeshTheme.minTapDimension)
                        .background(MeshTheme.p2pGreen.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(MeshTheme.p2pGreen.opacity(0.32), lineWidth: 0.8)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.applePressable)
                .accessibilityLabel("Nhắn tin mã hóa đầu cuối với \(peer.identity.displayName)")
            }
        }
        .padding(14)
        .meshCard()
    }
}
#endif
