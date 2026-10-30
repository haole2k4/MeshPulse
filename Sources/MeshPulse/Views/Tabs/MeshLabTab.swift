#if canImport(SwiftUI)
import MeshCore
import SwiftUI

/// Tab 4 (`Mesh Lab`): Interactive testbed for Mock vs Live Multipeer switching,
/// MANET/DTN routing strategies, Topology Blocker & physical link severing,
/// live Telemetry counters, and JSON `Packet Inspector`.
public struct MeshLabTab: View {
    public var coordinator: MeshCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingPacketInspector = false
    @State private var resetFeedbackCount = 0

    public init(coordinator: MeshCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                operatingModeSection
                routingStrategySection
                topologyControlSection
                telemetrySection
                packetInspectorSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(MeshTheme.background)
        .sheet(isPresented: $isShowingPacketInspector) {
            PacketInspectorSheet(coordinator: coordinator)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: resetFeedbackCount)
    }

    // MARK: - 1. Operating Mode (Mock vs Live Multipeer)

    private var operatingModeSection: some View {
        let mockBinding = Binding<Bool>(
            get: { coordinator.isMockMode },
            set: { newValue in
                withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                    coordinator.setMockMode(newValue)
                }
            }
        )

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Chế độ Vận hành", systemImage: "cpu.fill")
                    .font(.headline)
                    .foregroundStyle(MeshTheme.primaryText)

                Spacer()

                Text(coordinator.isMockMode ? "MOCK 3-NODE" : "LIVE RADIO")
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(coordinator.isMockMode ? MeshTheme.dtnIndigo : MeshTheme.p2pGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (coordinator.isMockMode ? MeshTheme.dtnIndigo : MeshTheme.p2pGreen).opacity(0.16),
                        in: Capsule()
                    )
            }

            Toggle(isOn: mockBinding) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mạng Mô phỏng 3 Trạm (Mock Mode)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MeshTheme.primaryText)

                    Text(
                        coordinator.isMockMode
                            ? "Đang giả lập 3 nút (Bạn, iPhone-B, iPhone-C) với tự động phản hồi ACK & bắc cầu ngay trên 1 máy."
                            : "Đang chạy bộ định tuyến phần cứng thực (MultipeerConnectivity BLE + AWDL)."
                    )
                    .font(.caption)
                    .foregroundStyle(MeshTheme.secondaryText)
                }
            }
            .tint(MeshTheme.dtnIndigo)
            .frame(minHeight: MeshTheme.minTapDimension)
            .sensoryFeedback(.selection, trigger: coordinator.isMockMode)

            if !coordinator.isMockMode, let statusNote = coordinator.radioStatusNote {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.meshAmber)
                    Text(statusNote)
                        .font(.caption)
                        .foregroundStyle(MeshTheme.secondaryText)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MeshTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(14)
        .meshCard()
    }

    // MARK: - 2. MANET / DTN Routing Strategy

    private var routingStrategySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Chiến lược Định tuyến & DTN", systemImage: "arrow.triangle.branch")
                .font(.headline)
                .foregroundStyle(MeshTheme.primaryText)

            ForEach(RoutingStrategy.allCases) { strategy in
                let isSelected = (coordinator.routingStrategy == strategy)
                Button {
                    withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                        coordinator.setRoutingStrategy(strategy)
                    }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isSelected ? MeshTheme.p2pGreen : MeshTheme.secondaryText)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(strategy.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(MeshTheme.primaryText)

                            Text(strategy.subtitle)
                                .font(.caption)
                                .foregroundStyle(MeshTheme.secondaryText)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: MeshTheme.minTapDimension, alignment: .leading)
                    .background(
                        isSelected ? MeshTheme.p2pGreen.opacity(0.12) : MeshTheme.elevatedSurface,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isSelected ? MeshTheme.p2pGreen.opacity(0.45) : MeshTheme.hairlineBorder,
                                lineWidth: 1
                            )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .meshCard()
        .sensoryFeedback(.selection, trigger: coordinator.routingStrategy)
    }

    // MARK: - 3. Topology Blocker & Mock Physical Links

    private var topologyControlSection: some View {
        let labPeers = coordinator.controllableLabPeers

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Kiểm soát Địa hình & Topology Blocker", systemImage: "hand.raised.slash.fill")
                    .font(.headline)
                    .foregroundStyle(MeshTheme.primaryText)

                Text("Chặn kết nối trực tiếp 1-Hop ở tầng thu để ép gói tin phải đi đường vòng Multi-Hop qua trạm trung gian ngay trên bàn làm việc.")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.secondaryText)
            }

            if labPeers.isEmpty {
                Text("Chưa có trạm lân cận nào để cấu hình chặn trực tiếp.")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.secondaryText)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 8) {
                    ForEach(labPeers) { peer in
                        blockerToggleRow(peer)
                    }
                }
            }

            if coordinator.isMockMode {
                Divider()
                    .overlay(MeshTheme.hairlineBorder)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "cable.connector.horizontal")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MeshTheme.dtnIndigo)
                        Text("Liên kết Vật lý Mô phỏng (Thử nghiệm Data Mule DTN)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MeshTheme.primaryText)
                    }

                    Text("Ngắt liên kết để cô lập trạm đích (tin nhắn tự lưu vào Hộp thư chờ DTN), sau đó nối lại để xem tự động đồng bộ bù.")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.secondaryText)

                    mockPhysicalLinkRow(
                        title: "\(coordinator.localDisplayName) (A) — iPhone-B",
                        peerA: SimulatedMeshNetwork.nodeAID,
                        peerB: SimulatedMeshNetwork.nodeBID
                    )
                    mockPhysicalLinkRow(
                        title: "iPhone-B — iPhone-C",
                        peerA: SimulatedMeshNetwork.nodeBID,
                        peerB: SimulatedMeshNetwork.nodeCID
                    )
                    mockPhysicalLinkRow(
                        title: "\(coordinator.localDisplayName) (A) — iPhone-C",
                        peerA: SimulatedMeshNetwork.nodeAID,
                        peerB: SimulatedMeshNetwork.nodeCID
                    )
                }
            }
        }
        .padding(14)
        .meshCard()
    }

    private func blockerToggleRow(_ peer: PeerSummary) -> some View {
        let isBlocked = coordinator.isPeerBlocked(peer.id)
        let binding = Binding<Bool>(
            get: { isBlocked },
            set: { blocked in
                withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                    coordinator.setPeerBlocked(peer.id, isBlocked: blocked)
                }
            }
        )

        return Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Chặn 1-Hop: \(peer.identity.displayName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MeshTheme.primaryText)

                    if isBlocked {
                        Text("ĐÃ CHẶN")
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(MeshTheme.sosCrimson)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(MeshTheme.sosCrimson.opacity(0.16), in: Capsule())
                    }
                }

                Text("\(peer.identity.nodeID) · \(linkSummaryText(peer.linkKind))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(MeshTheme.secondaryText)
            }
        }
        .tint(MeshTheme.sosCrimson)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: MeshTheme.minTapDimension)
        .background(MeshTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .sensoryFeedback(.selection, trigger: isBlocked)
    }

    private func mockPhysicalLinkRow(title: String, peerA: String, peerB: String) -> some View {
        let isConnected = coordinator.hasPhysicalLinkInMock(peerA, peerB)
        let binding = Binding<Bool>(
            get: { isConnected },
            set: { connected in
                withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                    coordinator.setPhysicalLinkInMock(peerA, peerB, isConnected: connected)
                }
            }
        )

        return Toggle(isOn: binding) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isConnected ? MeshTheme.p2pGreen : MeshTheme.sosCrimson)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(MeshTheme.primaryText)
            }
        }
        .tint(MeshTheme.p2pGreen)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minHeight: MeshTheme.minTapDimension)
        .background(MeshTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .sensoryFeedback(.selection, trigger: isConnected)
    }

    private func linkSummaryText(_ kind: LinkKind) -> String {
        switch kind {
        case .directP2P:
            "Trực tiếp 1-Hop"
        case let .relayedMesh(_, viaName, hops):
            "\(hops)-Hop qua \(viaName)"
        case .offlineDTN:
            "Ngoại tuyến DTN"
        }
    }

    // MARK: - 4. Real-Time Telemetry Grid (2x2)

    private var telemetrySection: some View {
        let stats = coordinator.telemetry
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ]

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Đo kiểm Telemetry Thời gian thực", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                    .foregroundStyle(MeshTheme.primaryText)

                Spacer()

                Button {
                    resetFeedbackCount += 1
                    coordinator.resetTelemetry()
                } label: {
                    Label("Đặt lại", systemImage: "arrow.counterclockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MeshTheme.secondaryText)
                        .padding(.horizontal, 12)
                        .frame(minHeight: MeshTheme.minTapDimension)
                        .background(MeshTheme.elevatedSurface, in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(MeshTheme.hairlineBorder, lineWidth: 1)
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Đặt lại bộ đếm thống kê Telemetry")
            }

            LazyVGrid(columns: columns, spacing: 10) {
                telemetryMetricTile(
                    title: "Gói phát / nhận",
                    value: "TX \(stats.txPackets) · RX \(stats.rxPackets)",
                    symbol: "arrow.up.arrow.down.circle.fill",
                    accent: MeshTheme.p2pGreen
                )

                telemetryMetricTile(
                    title: "Bắc cầu (Relayed)",
                    value: "\(stats.relayedPackets)",
                    symbol: "point.3.connected.trianglepath.dotted",
                    accent: MeshTheme.meshAmber
                )

                telemetryMetricTile(
                    title: "Chống bão & Chặn",
                    value: "\(stats.droppedDuplicates) trùng · \(stats.blockedIngressDrops) chặn",
                    symbol: "shield.lefthalf.filled",
                    accent: MeshTheme.dtnIndigo
                )

                telemetryMetricTile(
                    title: "Độ trễ RTT TB",
                    value: stats.averageRTTMs.map { "\($0) ms" } ?? "-- ms",
                    symbol: "waveform.path.ecg",
                    accent: MeshTheme.primaryText
                )
            }
        }
        .padding(14)
        .meshCard()
    }

    private func telemetryMetricTile(
        title: String,
        value: String,
        symbol: String,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(MeshTheme.secondaryText)
                    .lineLimit(1)
            }

            Text(value)
                .font(.subheadline.monospacedDigit().weight(.bold))
                .foregroundStyle(MeshTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MeshTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(MeshTheme.hairlineBorder, lineWidth: 1)
        }
    }

    // MARK: - 5. JSON Packet Inspector Launcher

    private var packetInspectorSection: some View {
        Button {
            isShowingPacketInspector = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(MeshTheme.p2pGreen)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Nhật ký Gói tin (Packet Inspector)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MeshTheme.primaryText)
                    Text("Soi khung gói tin MeshPacket JSON, TTL và lộ trình thực tế")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.secondaryText)
                }

                Spacer(minLength: 6)

                Text("\(coordinator.packetLogs.count)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(MeshTheme.primaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(MeshTheme.elevatedSurface, in: Capsule())

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MeshTheme.secondaryText)
            }
            .padding(14)
            .frame(minHeight: MeshTheme.minTapDimension)
            .meshCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Packet Inspector Sheet

private struct PacketInspectorSheet: View {
    private enum LogFilter: String, CaseIterable, Identifiable {
        case all = "Tất cả"
        case tx = "TX"
        case rx = "RX"
        case relay = "RELAY"
        case drop = "DROP"

        var id: String { rawValue }

        func matches(_ direction: PacketLogDirection) -> Bool {
            switch self {
            case .all:
                true
            case .tx:
                direction == .tx
            case .rx:
                direction == .rx
            case .relay:
                direction == .relay
            case .drop:
                direction == .dropDuplicate || direction == .dropBlocked || direction == .dropTTL
            }
        }
    }

    var coordinator: MeshCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var selectedFilter: LogFilter = .all

    private var filteredLogs: [PacketLogEntry] {
        coordinator.packetLogs.filter { selectedFilter.matches($0.direction) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LogFilter.allCases) { filter in
                            let active = (selectedFilter == filter)
                            Button {
                                selectedFilter = filter
                            } label: {
                                Text(filter.rawValue)
                                    .font(.caption.monospaced().weight(.bold))
                                    .foregroundStyle(active ? MeshTheme.background : MeshTheme.primaryText)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: MeshTheme.minTapDimension)
                                    .background(
                                        active ? MeshTheme.p2pGreen : MeshTheme.elevatedSurface,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .background(MeshTheme.cardSurface)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(MeshTheme.hairlineBorder).frame(height: 1)
                }

                ScrollView {
                    if filteredLogs.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tray")
                                .font(.title2)
                                .foregroundStyle(MeshTheme.secondaryText)
                            Text("Không có bản ghi gói tin phù hợp")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(MeshTheme.primaryText)
                        }
                        .padding(32)
                        .frame(maxWidth: .infinity)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(filteredLogs) { entry in
                                packetLogCard(entry)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .background(MeshTheme.background)
            .navigationTitle("Packet Inspector")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") {
                        dismiss()
                    }
                    .frame(minWidth: MeshTheme.minTapDimension, minHeight: MeshTheme.minTapDimension)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.selection, trigger: selectedFilter)
    }

    private func packetLogCard(_ entry: PacketLogEntry) -> some View {
        let dirColor = color(for: entry.direction)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(label(for: entry.direction))
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(dirColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(dirColor.opacity(0.16), in: Capsule())

                Text(entry.packetType.rawValue.uppercased())
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(MeshTheme.badgeText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(MeshTheme.elevatedSurface, in: Capsule())

                Spacer()

                Text("TTL \(entry.ttl) · \(entry.sizeBytes) B")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MeshTheme.secondaryText)
            }

            if !entry.routeDisplay.isEmpty {
                Text(entry.routeDisplay)
                    .font(.caption.monospaced())
                    .foregroundStyle(MeshTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Text(entry.note)
                    .font(.caption)
                    .foregroundStyle(MeshTheme.secondaryText)
                Spacer()
                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MeshTheme.secondaryText)
            }

            DisclosureGroup("Xem khung JSON thô") {
                Text(entry.rawJSON)
                    .font(.caption2.monospaced())
                    .foregroundStyle(MeshTheme.badgeText)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MeshTheme.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 4)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(MeshTheme.secondaryText)
        }
        .padding(12)
        .meshCard()
    }

    private func label(for direction: PacketLogDirection) -> String {
        switch direction {
        case .tx:
            "TX"
        case .rx:
            "RX"
        case .relay:
            "RELAY"
        case .dropDuplicate:
            "DROP·DUP"
        case .dropBlocked:
            "DROP·BLK"
        case .dropTTL:
            "DROP·TTL"
        }
    }

    private func color(for direction: PacketLogDirection) -> Color {
        switch direction {
        case .tx:
            MeshTheme.p2pGreen
        case .rx:
            MeshTheme.dtnIndigo
        case .relay:
            MeshTheme.meshAmber
        case .dropDuplicate, .dropBlocked, .dropTTL:
            MeshTheme.sosCrimson
        }
    }
}
#endif
