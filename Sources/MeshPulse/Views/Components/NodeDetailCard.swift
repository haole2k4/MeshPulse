#if canImport(SwiftUI)
import MeshCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Detailed Station Inspection Card modeled after the Meshtastic iOS "Node" layout:
/// - Visual Summary Row: 64x64pt soft-tinted circular avatar + circular SwiftUI `Gauge` measuring signal/latency
/// - Clean Flat Property Rows: Name, Node ID, Route path, and Public Key with one-tap Copy button
/// - Collapsible Action Pill: "Thao tác với trạm ⌄" revealing Ping, Encrypted Message, and Link Severing
public struct NodeDetailCard: View {
    public let peer: PeerSummary
    public var coordinator: MeshCoordinator

    @State private var isActionsExpanded = false
    @State private var hasCopiedKey = false
    @State private var pingFeedbackCount = 0

    public init(peer: PeerSummary, coordinator: MeshCoordinator) {
        self.peer = peer
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: 1. Visual Summary Row (64x64 Avatar & SwiftUI Gauge)
            HStack(alignment: .center, spacing: 14) {
                // Station Avatar Circle (64x64pt)
                ZStack {
                    Circle()
                        .fill(MeshTheme.emerald.opacity(0.16))
                        .frame(width: 64, height: 64)

                    Text(stationMonogram)
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(MeshTheme.emerald)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(peer.identity.displayName)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(MeshTheme.primaryText)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        LinkStatusBadge(linkKind: peer.linkKind)
                        if isBlocked {
                            Text("Đã chặn")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(MeshTheme.sosCrimson)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(MeshTheme.sosCrimson.opacity(0.18), in: Capsule())
                        }
                    }
                }

                Spacer()

                // Circular SwiftUI Gauge: Signal Quality & Latency
                Gauge(value: signalQualityPercent, in: 0...100) {
                    Text("Tín hiệu")
                } currentValueLabel: {
                    VStack(spacing: 0) {
                        Text("\(Int(signalQualityPercent))%")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(MeshTheme.primaryText)
                        Text(latencyLabel)
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(MeshTheme.secondaryText)
                    }
                }
                .gaugeStyle(.accessoryCircular)
                .tint(Gradient(colors: [.red, .yellow, MeshTheme.emerald]))
                .scaleEffect(1.15)
                .frame(width: 60, height: 60)
            }
            .padding(16)

            Divider()
                .overlay(MeshTheme.hairlineBorder)
                .padding(.leading, 16)

            // MARK: 2. Clean Flat Property Rows (No AI Slop Boxes)
            VStack(spacing: 0) {
                propertyRow(
                    icon: "person.fill",
                    title: "Tên trạm (Name)",
                    value: peer.identity.displayName
                )

                Divider()
                    .overlay(MeshTheme.hairlineBorder)
                    .padding(.leading, 44)

                propertyRow(
                    icon: "number",
                    title: "Định danh (Node ID)",
                    value: peer.identity.nodeID
                )

                Divider()
                    .overlay(MeshTheme.hairlineBorder)
                    .padding(.leading, 44)

                propertyRow(
                    icon: "arrow.triangle.branch",
                    title: "Lộ trình (Route)",
                    value: routeDescription
                )

                Divider()
                    .overlay(MeshTheme.hairlineBorder)
                    .padding(.leading, 44)

                publicKeyRow
            }
            .padding(.vertical, 4)

            Divider()
                .overlay(MeshTheme.hairlineBorder)
                .padding(.leading, 16)

            // MARK: 3. Collapsible Action Pill ("Thao tác với trạm ⌄")
            collapsibleActionSection
                .padding(14)
        }
        .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .sensoryFeedback(.impact(weight: .light), trigger: pingFeedbackCount)
        .sensoryFeedback(.success, trigger: hasCopiedKey)
    }

    // MARK: - Subcomponents

    private var stationMonogram: String {
        let name = peer.identity.displayName.uppercased()
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "-" })
        if parts.count >= 2 {
            let first = String(parts[0].prefix(2))
            let second = String(parts[1].prefix(2))
            return "\(first)\(second)"
        }
        return String(name.prefix(4))
    }

    private var signalQualityPercent: Double {
        if peer.linkKind == .offlineDTN {
            return 25.0
        }
        if let rtt = peer.lastRTTMilliseconds {
            if rtt < 35 { return 98.0 }
            if rtt < 80 { return 88.0 }
            if rtt < 150 { return 74.0 }
            return 60.0
        }
        switch peer.linkKind {
        case .directP2P: return 92.0
        case .relayedMesh: return 78.0
        case .offlineDTN: return 25.0
        }
    }

    private var latencyLabel: String {
        if let rtt = peer.lastRTTMilliseconds {
            return "\(rtt)ms"
        }
        return peer.linkKind == .offlineDTN ? "DTN" : "P2P"
    }

    private var routeDescription: String {
        switch peer.linkKind {
        case .directP2P:
            return "1-Hop P2P (Trực tiếp AWDL)"
        case let .relayedMesh(viaID, viaName, hops):
            return "\(hops)-Hop qua \(viaName) (\(viaID.prefix(6)))"
        case .offlineDTN:
            return "Ngoại tuyến (Lưu chờ DTN)"
        }
    }

    private var isBlocked: Bool {
        coordinator.blockedPeerIDs.contains(peer.id)
    }

    private func propertyRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MeshTheme.secondaryText)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(MeshTheme.secondaryText)

            Spacer()

            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MeshTheme.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var publicKeyRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MeshTheme.emerald)
                .frame(width: 20)

            Text("Khóa công khai (Key)")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(MeshTheme.secondaryText)

            Spacer()

            HStack(spacing: 8) {
                Text(peer.identity.publicKeyFingerprint ?? "E2EE-Active")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(MeshTheme.primaryText)
                    .lineLimit(1)

                Button {
                    copyPublicKey()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: hasCopiedKey ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .bold))
                        Text(hasCopiedKey ? "Đã chép" : "Chép")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(MeshTheme.emerald)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(MeshTheme.emerald.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var collapsibleActionSection: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    isActionsExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(isActionsExpanded ? "Thu gọn thao tác" : "Thao tác với trạm (Ping / Nhắn tin / Chặn)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MeshTheme.primaryText)

                    Spacer()

                    Image(systemName: isActionsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(MeshTheme.secondaryText)
                }
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(MeshTheme.elevatedSurface, in: Capsule())
            }
            .buttonStyle(.plain)

            if isActionsExpanded {
                HStack(spacing: 8) {
                    // Ping RTT Button
                    Button {
                        pingFeedbackCount += 1
                        coordinator.ping(peerID: peer.id)
                    } label: {
                        Label("Ping", systemImage: "waveform.path.ecg")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MeshTheme.primaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(MeshTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(peer.linkKind == .offlineDTN)
                    .opacity(peer.linkKind == .offlineDTN ? 0.45 : 1.0)

                    // Encrypted Chat Button
                    Button {
                        withAnimation {
                            coordinator.openDirectConversation(with: peer.id)
                        }
                    } label: {
                        Label("Nhắn tin", systemImage: "bubble.left.and.lock.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(MeshTheme.emerald, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    // Sever / Unblock 1-Hop Route
                    Button {
                        withAnimation {
                            coordinator.toggleTopologyBlock(for: peer.id)
                        }
                    } label: {
                        Label(isBlocked ? "Bỏ chặn" : "Chặn", systemImage: isBlocked ? "checkmark.circle" : "slash.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isBlocked ? MeshTheme.emerald : MeshTheme.sosCrimson)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(
                                (isBlocked ? MeshTheme.emerald : MeshTheme.sosCrimson).opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func copyPublicKey() {
        #if canImport(UIKit)
        let keyToCopy = peer.identity.publicKeyBase64 ?? peer.identity.nodeID
        UIPasteboard.general.string = keyToCopy
        #endif
        hasCopiedKey = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            hasCopiedKey = false
        }
    }
}
#endif
