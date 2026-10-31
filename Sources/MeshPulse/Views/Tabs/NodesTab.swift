#if canImport(SwiftUI)
import MeshCore
import SwiftUI

/// Tab 1 (`Trạm Mạng / Nodes`): Dedicated station inspection tab built to Meshtastic specifications:
/// - Prominent NodeDetailCard with circular avatar + SwiftUI Gauge signal meter
/// - Flat grouped table of all other stations in the mesh network
public struct NodesTab: View {
    public var coordinator: MeshCoordinator

    @State private var selectedPeerID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(coordinator: MeshCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header Title & Station Count
                headerSection

                if !coordinator.isRadioEnabled {
                    radioDisabledState
                } else if coordinator.peers.isEmpty {
                    scanningState
                } else {
                    // Hero Node Detail Card (Meshtastic Reference Layout)
                    if let activePeer = resolvedActivePeer {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("CHI TIẾT TRẠM ĐANG CHỌN")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(MeshTheme.secondaryText)
                                .padding(.horizontal, 4)

                            NodeDetailCard(peer: activePeer, coordinator: coordinator)
                        }
                    }

                    // Other Stations in the Mesh Network
                    stationsListSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 96)
        }
        .background(MeshTheme.background)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Trạm Mạng")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(MeshTheme.primaryText)

                Text(coordinator.isRadioEnabled
                     ? "\(coordinator.peers.count) trạm đang trực tuyến trong vùng phủ sóng"
                     : "Sóng vô tuyến đang tắt")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.secondaryText)
            }

            Spacer()

            // Radio status indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(coordinator.isRadioEnabled ? MeshTheme.emerald : MeshTheme.sosCrimson)
                    .frame(width: 8, height: 8)
                Text(coordinator.isRadioEnabled ? "ONLINE" : "OFFLINE")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(coordinator.isRadioEnabled ? MeshTheme.emerald : MeshTheme.sosCrimson)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (coordinator.isRadioEnabled ? MeshTheme.emerald : MeshTheme.sosCrimson).opacity(0.14),
                in: Capsule()
            )
        }
    }

    // MARK: - Station List Section

    private var stationsListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TẤT CẢ TRẠM LÂN CẬN (\(coordinator.peers.count))")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(MeshTheme.secondaryText)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(coordinator.peers.enumerated()), id: \.element.id) { index, peer in
                    stationRow(peer)

                    if index < coordinator.peers.count - 1 {
                        Divider()
                            .overlay(MeshTheme.hairlineBorder)
                            .padding(.leading, 56)
                    }
                }
            }
            .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func stationRow(_ peer: PeerSummary) -> some View {
        let isSelected = resolvedActivePeer?.id == peer.id

        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedPeerID = peer.id
            }
        } label: {
            HStack(spacing: 12) {
                // 38x38 Station Avatar
                ZStack {
                    Circle()
                        .fill(isSelected ? MeshTheme.emerald.opacity(0.25) : MeshTheme.elevatedSurface)
                        .frame(width: 38, height: 38)

                    Text(peerMonogram(peer))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? MeshTheme.emerald : MeshTheme.primaryText)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.identity.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MeshTheme.primaryText)
                        .lineLimit(1)

                    Text(peer.identity.nodeID.prefix(10) + "…")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(MeshTheme.secondaryText)
                }

                Spacer()

                HStack(spacing: 8) {
                    LinkStatusBadge(linkKind: peer.linkKind)

                    if let rtt = peer.lastRTTMilliseconds {
                        Text("\(rtt)ms")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(MeshTheme.emeraldLight)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MeshTheme.secondaryText.opacity(0.5))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var resolvedActivePeer: PeerSummary? {
        if let id = selectedPeerID, let match = coordinator.peers.first(where: { $0.id == id }) {
            return match
        }
        return coordinator.peers.first
    }

    private func peerMonogram(_ peer: PeerSummary) -> String {
        let name = peer.identity.displayName.uppercased()
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "-" })
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))"
        }
        return String(name.prefix(2))
    }

    // MARK: - Empty States

    private var radioDisabledState: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(MeshTheme.sosCrimson)

            Text("Sóng vô tuyến đang tắt")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(MeshTheme.primaryText)

            Text("Bật lại sóng để tự động quét và kết nối với các iPhone xung quanh qua BLE và AWDL.")
                .font(.caption)
                .foregroundStyle(MeshTheme.secondaryText)
                .multilineTextAlignment(.center)

            Button {
                withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                    coordinator.toggleRadio()
                }
            } label: {
                Text("Bật sóng ngoại tuyến")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 20)
                    .frame(height: 40)
                    .background(MeshTheme.emerald, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var scanningState: some View {
        VStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(MeshTheme.emerald)

            Text("Đang quét các trạm lân cận...")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(MeshTheme.primaryText)

            Text("Khởi động MeshPulse trên máy khác hoặc bật Mock Mode trong tab Mesh Lab để kiểm thử.")
                .font(.caption)
                .foregroundStyle(MeshTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
#endif
