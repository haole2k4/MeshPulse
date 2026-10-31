#if canImport(SwiftUI)
import MeshCore
import SwiftUI

/// Tab 2 (`Sơ đồ / Map`): Dedicated topology and multi-hop routing graph.
/// - Glass circle button `<` inspired by the top-left navigation control in the Meshtastic reference
/// - Real-time canvas with animated packet pulses, P2P (Emerald) & Relayed (Amber) links
/// - Flat 24pt rounded surface, clean legend, and routing strategy indicator
public struct MapTab: View {
    public var coordinator: MeshCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var canvasResetTrigger = 0

    public init(coordinator: MeshCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Top Navigation Bar with Glass Circle Button
                topNavigationBar

                // Real-Time Canvas Topology Card
                radarCanvasCard

                // Routing Strategy & Legend Bar
                strategyAndLegendSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 96)
        }
        .background(MeshTheme.background)
    }

    // MARK: - Top Navigation Bar

    private var topNavigationBar: some View {
        HStack(alignment: .center, spacing: 12) {
            // Glass Circle Button like `<` in Meshtastic reference
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    canvasResetTrigger += 1
                }
            } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(MeshTheme.emerald)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    }
                    .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 3)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text("Sơ đồ Định tuyến")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(MeshTheme.primaryText)

                Text("\(coordinator.peers.count) trạm · \(coordinator.topologyEdges.count) liên kết")
                    .font(.caption2)
                    .foregroundStyle(MeshTheme.secondaryText)
            }

            Spacer()

            // Active Routing Strategy Pill
            HStack(spacing: 5) {
                Image(systemName: coordinator.routingStrategy.systemImage)
                    .font(.system(size: 10, weight: .bold))
                Text(coordinator.routingStrategy.title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(MeshTheme.emerald)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(MeshTheme.emerald.opacity(0.14), in: Capsule())
        }
    }

    // MARK: - Radar Canvas Card

    private var radarCanvasCard: some View {
        VStack(alignment: .leading, spacing: 12) {
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

                    drawLocalCenterNode(
                        in: &context,
                        at: positions[coordinator.localIdentity.nodeID] ?? CGPoint(x: size.width / 2, y: size.height / 2)
                    )
                }
                .frame(maxWidth: .infinity, minHeight: 320)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Đồ thị mạng lưới đa bước nhảy")
            }
        }
        .padding(16)
        .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Legend & Strategy

    private var strategyAndLegendSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Capsule()
                        .fill(MeshTheme.emerald)
                        .frame(width: 14, height: 4)
                    Text("1-Hop P2P")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(MeshTheme.secondaryText)
                }

                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        Capsule().fill(MeshTheme.meshAmber).frame(width: 5, height: 4)
                        Capsule().fill(MeshTheme.meshAmber).frame(width: 5, height: 4)
                    }
                    Text("Bắc cầu Multi-Hop")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(MeshTheme.secondaryText)
                }

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(MeshTheme.dtnIndigo)
                        .frame(width: 6, height: 6)
                    Text("DTN: \(coordinator.dtnRecords.count)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(MeshTheme.secondaryText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Canvas Rendering

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

        let innerRx = max(60, min(size.width * 0.28, 110))
        let innerRy = max(50, min(size.height * 0.28, 80))
        let outerRx = max(95, min(size.width * 0.42, 165))
        let outerRy = max(75, min(size.height * 0.42, 110))

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
        let minY: CGFloat = 28
        let maxY = max(minY, size.height - 38)
        return CGPoint(
            x: min(maxX, max(minX, point.x)),
            y: min(maxY, max(minY, point.y))
        )
    }

    private func drawTopologyEdges(in context: inout GraphicsContext, positions: [String: CGPoint]) {
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
                    with: .color(MeshTheme.emerald.opacity(0.85)),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
            } else {
                context.stroke(
                    path,
                    with: .color(MeshTheme.meshAmber.opacity(0.85)),
                    style: StrokeStyle(lineWidth: 2.0, lineCap: .round, dash: [6, 4])
                )
            }
        }
    }

    private func drawActivePulses(in context: inout GraphicsContext, at now: Date, positions: [String: CGPoint]) {
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
                : (pulse.isDirectP2P ? MeshTheme.emerald : MeshTheme.meshAmber)

            let haloRect = CGRect(x: current.x - 9, y: current.y - 9, width: 18, height: 18)
            context.fill(Path(ellipseIn: haloRect), with: .color(color.opacity(0.3)))

            let coreRect = CGRect(x: current.x - 4, y: current.y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: coreRect), with: .color(color))
        }
    }

    private func drawPeerNodes(in context: inout GraphicsContext, positions: [String: CGPoint]) {
        for peer in coordinator.peers {
            guard let pt = positions[peer.id] else { continue }
            let accent = MeshTheme.color(for: peer.linkKind)
            let isOffline = peer.linkKind == .offlineDTN

            let outerRect = CGRect(x: pt.x - 14, y: pt.y - 14, width: 28, height: 28)
            context.fill(Path(ellipseIn: outerRect), with: .color(MeshTheme.elevatedSurface))
            context.stroke(
                Path(ellipseIn: outerRect),
                with: .color(accent.opacity(isOffline ? 0.45 : 0.95)),
                style: StrokeStyle(lineWidth: 2, dash: isOffline ? [3, 3] : [])
            )

            let dotRect = CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: dotRect), with: .color(accent))

            let label = context.resolve(
                Text(peer.identity.displayName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isOffline ? MeshTheme.secondaryText : MeshTheme.primaryText)
            )
            context.draw(label, at: CGPoint(x: pt.x, y: pt.y + 18), anchor: .top)
        }
    }

    private func drawLocalCenterNode(in context: inout GraphicsContext, at pt: CGPoint) {
        let accent = coordinator.isRadioEnabled ? MeshTheme.emerald : MeshTheme.sosCrimson
        let haloRect = CGRect(x: pt.x - 22, y: pt.y - 22, width: 44, height: 44)
        context.fill(Path(ellipseIn: haloRect), with: .color(accent.opacity(0.16)))

        let nodeRect = CGRect(x: pt.x - 15, y: pt.y - 15, width: 30, height: 30)
        context.fill(Path(ellipseIn: nodeRect), with: .color(MeshTheme.elevatedSurface))
        context.stroke(Path(ellipseIn: nodeRect), with: .color(accent), lineWidth: 2.2)

        let centerDot = CGRect(x: pt.x - 5.5, y: pt.y - 5.5, width: 11, height: 11)
        context.fill(Path(ellipseIn: centerDot), with: .color(accent))

        let title = context.resolve(
            Text("\(coordinator.localDisplayName) (Bạn)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(MeshTheme.primaryText)
        )
        context.draw(title, at: CGPoint(x: pt.x, y: pt.y + 19), anchor: .top)
    }
}
#endif
