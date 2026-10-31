#if canImport(SwiftUI)
import MeshCore
import SwiftUI

/// Tab 4 (`Mesh Lab / Settings`): Native iOS `.insetGrouped` settings and testbed:
/// - Inset Grouped list style matching Apple Settings
/// - Colored SF Symbols on the left, attribute name in the middle, and switches/values on the right
/// - Mock mode, Routing Strategies, Topology Blocker, Telemetry counters, and Packet Inspector
public struct MeshLabTab: View {
    public var coordinator: MeshCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingPacketInspector = false
    @State private var isShowingRenameAlert = false
    @State private var draftDisplayName = ""
    @State private var resetFeedbackCount = 0

    public init(coordinator: MeshCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        NavigationStack {
            List {
                // Section 1: Hardware & Operating Mode
                operatingSection

                // Section 2: Routing Strategies
                routingStrategySection

                // Section 3: Topology Blocker (1-Hop Link Severing)
                topologyBlockerSection

                // Section 4: Real-Time Telemetry Counters
                telemetrySection

                // Section 5: Packet Inspector & Diagnostics
                diagnosticsSection

                // Clearance Spacer so bottom items scroll completely above Floating Glass TabBar
                Section {
                    Color.clear
                        .frame(height: 84)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(MeshTheme.background)
            .navigationTitle("Mesh Lab")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
        }
        .sheet(isPresented: $isShowingPacketInspector) {
            PacketInspectorSheet(coordinator: coordinator)
        }
        .alert("Đổi tên hiển thị", isPresented: $isShowingRenameAlert) {
            TextField("Biệt danh trạm", text: $draftDisplayName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Button("Hủy", role: .cancel) {}
            Button("Lưu") {
                coordinator.updateDisplayName(draftDisplayName)
            }
        } message: {
            Text("Tên hiển thị sẽ được quảng bá tới các nút lân cận trong mạng.")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: resetFeedbackCount)
    }

    // MARK: - Section 1: Hardware & Operating Mode

    private var operatingSection: some View {
        Section("VẬN HÀNH & SÓNG NGOẠI TUYẾN") {
            // Radio Power Toggle
            Toggle(isOn: Binding(
                get: { coordinator.isRadioEnabled },
                set: { _ in
                    withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                        coordinator.toggleRadio()
                    }
                }
            )) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sóng Ngoại tuyến (Radio)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(MeshTheme.primaryText)
                        Text(coordinator.isRadioEnabled ? "BLE + Wi-Fi Direct (AWDL) đang phát" : "Đã ngắt toàn bộ sóng")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.secondaryText)
                    }
                } icon: {
                    settingIcon("antenna.radiowaves.left.and.right", color: coordinator.isRadioEnabled ? MeshTheme.emerald : MeshTheme.sosCrimson)
                }
            }
            .tint(MeshTheme.emerald)

            // Mock Mode Toggle
            Toggle(isOn: Binding(
                get: { coordinator.isMockMode },
                set: { newValue in
                    withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                        coordinator.setMockMode(newValue)
                    }
                }
            )) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mô phỏng 3 Trạm (Mock Mode)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(MeshTheme.primaryText)
                        Text(coordinator.isMockMode ? "Giả lập Bạn, iPhone-B, iPhone-C" : "Phần cứng thật MultipeerConnectivity")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.secondaryText)
                    }
                } icon: {
                    settingIcon("cpu.fill", color: coordinator.isMockMode ? MeshTheme.dtnIndigo : MeshTheme.emerald)
                }
            }
            .tint(MeshTheme.dtnIndigo)

            // Display Name Row
            Button {
                draftDisplayName = coordinator.localDisplayName
                isShowingRenameAlert = true
            } label: {
                HStack {
                    Label {
                        Text("Tên trạm hiển thị")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(MeshTheme.primaryText)
                    } icon: {
                        settingIcon("person.fill", color: MeshTheme.emerald)
                    }

                    Spacer()

                    Text(coordinator.localDisplayName)
                        .font(.system(size: 14))
                        .foregroundStyle(MeshTheme.secondaryText)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MeshTheme.secondaryText.opacity(0.6))
                }
            }
            .buttonStyle(.plain)

            // Node ID Row
            HStack {
                Label {
                    Text("Định danh trạm")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MeshTheme.primaryText)
                } icon: {
                    settingIcon("number", color: MeshTheme.secondaryText)
                }

                Spacer()

                Text(coordinator.localNodeID)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(MeshTheme.secondaryText)
            }
        }
    }

    // MARK: - Section 2: Routing Strategies

    private var routingStrategySection: some View {
        Section("CHIẾN LƯỢC ĐỊNH TUYẾN (MANET & DTN)") {
            ForEach(RoutingStrategy.allCases) { strategy in
                let isSelected = coordinator.routingStrategy == strategy

                Button {
                    withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                        coordinator.setRoutingStrategy(strategy)
                    }
                } label: {
                    HStack(spacing: 12) {
                        settingIcon(strategy.systemImage, color: isSelected ? MeshTheme.emerald : MeshTheme.secondaryText)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(strategy.title)
                                .font(.system(size: 15, weight: isSelected ? .bold : .semibold))
                                .foregroundStyle(isSelected ? MeshTheme.emerald : MeshTheme.primaryText)

                            Text(strategyDescription(strategy))
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.secondaryText)
                        }

                        Spacer()

                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(MeshTheme.emerald)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Section 3: Topology Blocker

    private var topologyBlockerSection: some View {
        Section("TOPOLOGY BLOCKER (CẮT ĐỨT LIÊN KẾT 1-HOP)") {
            Text("Chặn nhận gói tin trực tiếp 1-Hop để ép bản tin phải chuyển tiếp vòng qua các máy khác.")
                .font(.caption2)
                .foregroundStyle(MeshTheme.secondaryText)

            let peers = coordinator.controllableLabPeers
            if peers.isEmpty {
                Text("Không có trạm lân cận để cấu hình")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.secondaryText)
            } else {
                ForEach(peers) { peer in
                    let isBlocked = coordinator.isPeerBlocked(peer.id)

                    Toggle(isOn: Binding(
                        get: { isBlocked },
                        set: { blocked in
                            withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                                coordinator.setPeerBlocked(peer.id, isBlocked: blocked)
                            }
                        }
                    )) {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(peer.identity.displayName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(MeshTheme.primaryText)

                                    if isBlocked {
                                        Text("CHẶN")
                                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                            .foregroundStyle(MeshTheme.sosCrimson)
                                    }
                                }
                                Text(peer.identity.nodeID.prefix(12) + "…")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(MeshTheme.secondaryText)
                            }
                        } icon: {
                            settingIcon(isBlocked ? "slash.circle.fill" : "link", color: isBlocked ? MeshTheme.sosCrimson : MeshTheme.emerald)
                        }
                    }
                    .tint(MeshTheme.sosCrimson)
                }
            }
        }
    }

    // MARK: - Section 4: Real-Time Telemetry

    private var telemetrySection: some View {
        let stats = coordinator.telemetry

        return Section("THÔNG SỐ VIỄN TRẮC (TELEMETRY)") {
            telemetryRow(title: "Gói tin đã gửi (TX)", value: "\(stats.txPackets)", icon: "arrow.up.circle.fill", color: MeshTheme.emerald)
            telemetryRow(title: "Gói tin đã nhận (RX)", value: "\(stats.rxPackets)", icon: "arrow.down.circle.fill", color: MeshTheme.emeraldLight)
            telemetryRow(title: "Gói tin bắc cầu (Relayed)", value: "\(stats.relayedPackets)", icon: "point.3.connected.trianglepath.dotted", color: MeshTheme.meshAmber)
            telemetryRow(title: "Lọc bỏ trùng lặp (Dropped)", value: "\(stats.droppedDuplicates)", icon: "xmark.circle.fill", color: MeshTheme.secondaryText)
            telemetryRow(title: "Gói tin chặn Ingress (Blocked)", value: "\(stats.blockedIngressDrops)", icon: "slash.circle.fill", color: MeshTheme.sosCrimson)

            Button {
                resetFeedbackCount += 1
                coordinator.resetTelemetry()
            } label: {
                HStack {
                    Label("Đặt lại bộ đếm Telemetry", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MeshTheme.secondaryText)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Section 5: Diagnostics

    private var diagnosticsSection: some View {
        Section("NHẬT KÝ & KIỂM TRA GÓI TIN") {
            Button {
                isShowingPacketInspector = true
            } label: {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Xem Packet Inspector")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(MeshTheme.primaryText)
                            Text("Xem luồng gói tin JSON thô thời gian thực")
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.secondaryText)
                        }
                    } icon: {
                        settingIcon("doc.text.magnifyingglass", color: MeshTheme.emerald)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MeshTheme.secondaryText.opacity(0.6))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if coordinator.isMockMode {
                Button {
                    resetFeedbackCount += 1
                    coordinator.resetMockScenario()
                } label: {
                    HStack {
                        Label {
                            Text("Khôi phục kịch bản mô phỏng gốc")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(MeshTheme.sosCrimson)
                        } icon: {
                            settingIcon("arrow.triangle.2.circlepath", color: MeshTheme.sosCrimson)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private func settingIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: 28, height: 28)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func telemetryRow(title: String, value: String, icon: String, color: Color) -> some View {
        HStack {
            Label {
                Text(title)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(MeshTheme.primaryText)
            } icon: {
                settingIcon(icon, color: color)
            }

            Spacer()

            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private func strategyDescription(_ strategy: RoutingStrategy) -> String {
        switch strategy {
        case .managedFlooding:
            "Quảng bá lụt kèm bộ nhớ đệm SeenCache ngăn bão mạng."
        case .sprayAndWait:
            "Giới hạn số bản sao (quota = 4) rồi chờ kết nối đích."
        case .epidemic:
            "Lưu và chuyển tiếp ngoại tuyến qua véc-tơ tóm tắt SummaryVector."
        }
    }
}

// MARK: - Packet Inspector Sheet

private struct PacketInspectorSheet: View {
    var coordinator: MeshCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var selectedFilter: PacketFilter = .all

    private enum PacketFilter: String, CaseIterable, Identifiable {
        case all = "Tất cả"
        case tx = "TX"
        case rx = "RX"
        case relay = "Bắc cầu"
        case drop = "Bỏ qua"

        var id: String { rawValue }
    }

    private var filteredLogs: [PacketLogEntry] {
        let all = coordinator.packetLogs
        switch selectedFilter {
        case .all:
            return all
        case .tx:
            return all.filter { $0.direction == .tx }
        case .rx:
            return all.filter { $0.direction == .rx }
        case .relay:
            return all.filter { $0.direction == .relay }
        case .drop:
            return all.filter {
                $0.direction == .dropDuplicate || $0.direction == .dropBlocked || $0.direction == .dropTTL
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Lọc gói tin", selection: $selectedFilter) {
                    ForEach(PacketFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                ScrollView {
                    if filteredLogs.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "tray.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(MeshTheme.secondaryText)
                            Text("Không có bản ghi gói tin phù hợp")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(MeshTheme.primaryText)
                        }
                        .padding(40)
                        .frame(maxWidth: .infinity)
                    } else {
                        LazyVStack(spacing: 12) {
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
                    Button("Xong") { dismiss() }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(MeshTheme.emerald)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func packetLogCard(_ entry: PacketLogEntry) -> some View {
        let dirColor = color(for: entry.direction)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(entry.direction.rawValue.uppercased())
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(dirColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(dirColor.opacity(0.16), in: Capsule())

                Text(entry.packetType.rawValue.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(MeshTheme.primaryText)
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
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(MeshTheme.primaryText)
                    .lineLimit(1)
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

            DisclosureGroup("Xem JSON thô") {
                Text(entry.rawJSON)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(MeshTheme.secondaryText)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MeshTheme.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 4)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(MeshTheme.secondaryText)
        }
        .padding(14)
        .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func color(for direction: PacketLogDirection) -> Color {
        switch direction {
        case .tx: return MeshTheme.emerald
        case .rx: return MeshTheme.dtnIndigo
        case .relay: return MeshTheme.meshAmber
        case .dropDuplicate, .dropBlocked, .dropTTL: return MeshTheme.sosCrimson
        }
    }
}
#endif
