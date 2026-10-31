#if canImport(SwiftUI)
import MeshCore
import SwiftUI

/// Dynamic Island Status Bar for MeshPulse.
/// Embraces the iPhone Dynamic Island hardware geometry with a glanceable compact pill
/// and an interactive expanded card for real-time mesh radio links, DTN outbox transfers,
/// station identity, and emergency SOS broadcast.
public struct TopStatusHeader: View {
    private static let sosHoldDuration: TimeInterval = 1.5

    public var coordinator: MeshCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isIslandExpanded = false
    @State private var isShowingRenameAlert = false
    @State private var draftDisplayName = ""

    @State private var isPressingSOS = false
    @State private var sosPressStartDate: Date?
    @State private var didFireCurrentSOSHold = false
    @State private var sosTriggerCount = 0
    @State private var sosHoldTask: Task<Void, Never>?

    public init(coordinator: MeshCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(spacing: 8) {
            dynamicIslandCapsule
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 6)

            if isPressingSOS {
                sosHoldHintPill
                    .padding(.horizontal, 14)
                    .transition(.opacity)
            }
        }
        .background {
            MeshTheme.background.opacity(0.85)
                .background(.ultraThinMaterial)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MeshTheme.hairlineBorder)
                .frame(height: 0.8)
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: isIslandExpanded)
        .animation(MeshTheme.animation(reduceMotion: reduceMotion), value: isPressingSOS)
        .animation(MeshTheme.animation(reduceMotion: reduceMotion), value: coordinator.activeSOSBanner?.id)
        .alert("Đổi tên hiển thị", isPresented: $isShowingRenameAlert) {
            TextField("Biệt danh trạm (Display Name)", text: $draftDisplayName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Button("Hủy", role: .cancel) {}
            Button("Lưu") {
                coordinator.updateDisplayName(draftDisplayName)
            }
        } message: {
            Text("Tên hiển thị sẽ được quảng bá tới các nút lân cận trong mạng lưới ngoại tuyến.")
        }
    }

    // MARK: - Dynamic Island Pill & Expanded Card

    private var dynamicIslandCapsule: some View {
        VStack(spacing: 0) {
            if isIslandExpanded {
                expandedIslandView
            } else {
                compactIslandView
            }
        }
        .background(Color.black, in: RoundedRectangle(cornerRadius: isIslandExpanded ? 24 : 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isIslandExpanded ? 24 : 22, style: .continuous)
                .strokeBorder(
                    coordinator.activeSOSBanner != nil
                        ? MeshTheme.sosCrimson.opacity(0.65)
                        : Color.white.opacity(0.14),
                    lineWidth: coordinator.activeSOSBanner != nil ? 1.5 : 0.8
                )
        }
        .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
    }

    // MARK: - 1. Compact Island State (Hardware Pill)

    private var compactIslandView: some View {
        Button {
            isIslandExpanded = true
        } label: {
            HStack(spacing: 8) {
                // Leading: Radio Wave / Peer Pulse Indicator
                HStack(spacing: 5) {
                    if coordinator.isRadioEnabled {
                        Circle()
                            .fill(MeshTheme.p2pGreen)
                            .frame(width: 8, height: 8)
                            .shadow(color: MeshTheme.p2pGreen.opacity(0.6), radius: 4)
                        Text("\(coordinator.directP2PCount)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(MeshTheme.primaryText)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(MeshTheme.sosCrimson)
                    }
                }
                .padding(.leading, 6)

                Spacer(minLength: 4)

                // Center: Dynamic status or Station name
                if let sos = coordinator.activeSOSBanner {
                    HStack(spacing: 5) {
                        Image(systemName: "light.beacon.max.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(MeshTheme.sosCrimson)
                        Text("SOS: \(sos.senderName)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(MeshTheme.sosCrimson)
                            .lineLimit(1)
                    }
                } else {
                    HStack(spacing: 4) {
                        Text(coordinator.localDisplayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MeshTheme.primaryText)
                            .lineLimit(1)

                        if coordinator.isMockMode {
                            Text("MOCK")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                .foregroundStyle(MeshTheme.dtnIndigo)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(MeshTheme.dtnIndigo.opacity(0.2), in: Capsule())
                        }
                    }
                }

                Spacer(minLength: 4)

                // Trailing: SOS / DTN / Relay status
                HStack(spacing: 6) {
                    if coordinator.activeSOSBanner != nil {
                        Text("KHẨN")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(MeshTheme.sosCrimson, in: Capsule())
                    } else if !coordinator.dtnRecords.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "tray.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text("\(coordinator.dtnRecords.count)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                        .foregroundStyle(MeshTheme.dtnIndigo)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(MeshTheme.dtnIndigo.opacity(0.18), in: Capsule())
                    } else if coordinator.isRadioEnabled {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(MeshTheme.meshAmber)
                                .frame(width: 6, height: 6)
                            Text("\(coordinator.meshRelayedCount)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(MeshTheme.secondaryText)
                        }
                    } else {
                        Text("OFF")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(MeshTheme.sosCrimson)
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(MeshTheme.secondaryText.opacity(0.7))
                }
                .padding(.trailing, 6)
            }
            .frame(height: 40)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.applePressable(scaleDown: 0.98, pressedOpacity: 0.9))
        .sensoryFeedback(.impact(weight: .light), trigger: isIslandExpanded)
    }

    // MARK: - 2. Expanded Island State (Full Card)

    private var expandedIslandView: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Bar inside Expanded Island
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(coordinator.isRadioEnabled ? MeshTheme.p2pGreen : MeshTheme.sosCrimson)

                    Text("MeshPulse · Dynamic Island")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(MeshTheme.secondaryText)
                }

                Spacer()

                Button {
                    isIslandExpanded = false
                } label: {
                    Image(systemName: "chevron.up.circle.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(MeshTheme.secondaryText)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.applePressable)
                .sensoryFeedback(.impact(weight: .light), trigger: isIslandExpanded)
            }

            // Real-Time Link Matrix (3 Glancable Badges)
            HStack(spacing: 8) {
                islandMetricPill(
                    title: "1-Hop P2P",
                    count: "\(coordinator.directP2PCount)",
                    color: MeshTheme.p2pGreen,
                    icon: "antenna.radiowaves.left.and.right"
                )

                islandMetricPill(
                    title: "Bắc cầu Mesh",
                    count: "\(coordinator.meshRelayedCount)",
                    color: MeshTheme.meshAmber,
                    icon: "point.3.connected.trianglepath.dotted"
                )

                islandMetricPill(
                    title: "Chờ DTN",
                    count: "\(coordinator.dtnRecords.count)",
                    color: MeshTheme.dtnIndigo,
                    icon: "tray.fill"
                )
            }

            // Quick Station Identity & Fast Radio Switch Row
            HStack(spacing: 10) {
                Button {
                    draftDisplayName = coordinator.localDisplayName
                    isShowingRenameAlert = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.body)
                            .foregroundStyle(MeshTheme.p2pGreen)

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(coordinator.localDisplayName)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(MeshTheme.primaryText)
                                    .lineLimit(1)
                                Image(systemName: "pencil")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(MeshTheme.secondaryText)
                            }
                            Text(coordinator.localNodeID.prefix(14) + "…")
                                .font(.caption2.monospaced())
                                .foregroundStyle(MeshTheme.secondaryText)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(MeshTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.applePressable)

                Button {
                    withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                        coordinator.toggleRadio()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: coordinator.isRadioEnabled ? "power" : "power.circle.fill")
                            .font(.caption.weight(.bold))
                        Text(coordinator.isRadioEnabled ? "Tắt sóng" : "Bật sóng")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(coordinator.isRadioEnabled ? MeshTheme.primaryText : MeshTheme.p2pGreen)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(
                        coordinator.isRadioEnabled ? MeshTheme.elevatedSurface : MeshTheme.p2pGreen.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                coordinator.isRadioEnabled ? MeshTheme.hairlineBorder : MeshTheme.p2pGreen.opacity(0.4),
                                lineWidth: 0.8
                            )
                    }
                }
                .buttonStyle(.applePressable)
                .sensoryFeedback(.selection, trigger: coordinator.isRadioEnabled)
            }

            // Emergency SOS Alert or SOS Hold Trigger Section
            if let sos = coordinator.activeSOSBanner {
                emergencySOSIslandCard(sos)
            } else {
                HStack(spacing: 12) {
                    sosHoldButton

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Phát tín hiệu cứu nạn SOS")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MeshTheme.primaryText)
                        Text("Nhấn giữ vòng tròn 1.5 giây để phát tọa độ GPS khẩn cấp tới mọi máy trong bán kính bước nhảy.")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.secondaryText)
                    }
                }
                .padding(10)
                .background(MeshTheme.elevatedSurface.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(14)
    }

    private func islandMetricPill(title: String, count: String, color: Color, icon: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(count)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(color)

            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(MeshTheme.secondaryText)
                .lineLimit(1)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(color.opacity(0.28), lineWidth: 0.8)
        }
    }

    private func emergencySOSIslandCard(_ item: ChatThreadItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "light.beacon.max.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(MeshTheme.sosCrimson)

                Text(item.isOutgoing ? "BẠN ĐANG PHÁT SOS" : "SOS TỪ \(item.senderName)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(MeshTheme.sosCrimson)

                Spacer()

                Text("\(item.hopCount)H")
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(MeshTheme.sosCrimson)
            }

            Text(item.text)
                .font(.caption.weight(.medium))
                .foregroundStyle(MeshTheme.primaryText)
                .lineLimit(2)

            HStack(spacing: 8) {
                Button {
                    withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                        coordinator.selectedTab = .broadcast
                        coordinator.dismissSOSBanner()
                        isIslandExpanded = false
                    }
                } label: {
                    Text("Xem trên Kênh Chung")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(MeshTheme.sosCrimson, in: Capsule())
                }
                .buttonStyle(.applePressable)

                Spacer()

                Button {
                    withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                        coordinator.dismissSOSBanner()
                    }
                } label: {
                    Text("Bỏ qua")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MeshTheme.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                }
                .buttonStyle(.applePressable)
            }
        }
        .padding(12)
        .background(MeshTheme.sosCrimson.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(MeshTheme.sosCrimson.opacity(0.55), lineWidth: 1)
        }
    }

    // MARK: - SOS Hold Control & Progress

    private var sosHoldButton: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPressingSOS)) { context in
            let progress = holdProgress(at: context.date)

            ZStack {
                Circle()
                    .fill(
                        isPressingSOS
                            ? MeshTheme.sosCrimson.opacity(0.32)
                            : MeshTheme.sosCrimson.opacity(0.16)
                    )

                Circle()
                    .strokeBorder(MeshTheme.sosCrimson.opacity(0.36), lineWidth: 1.5)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        MeshTheme.sosCrimson,
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .padding(1.5)

                VStack(spacing: 1) {
                    Image(systemName: "light.beacon.max.fill")
                        .font(.caption.weight(.bold))
                    Text("SOS")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                }
                .foregroundStyle(MeshTheme.sosCrimson)
            }
            .frame(width: 44, height: 44)
            .scaleEffect(isPressingSOS && !reduceMotion ? 0.94 : 1.0)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = value.location.x - 22
                        let dy = value.location.y - 22
                        if hypot(dx, dy) > 54 {
                            cancelSOSHold()
                            return
                        }
                        beginSOSHoldIfNeeded()
                    }
                    .onEnded { _ in
                        cancelSOSHold()
                    }
            )
            .sensoryFeedback(.impact(weight: .light), trigger: isPressingSOS)
            .sensoryFeedback(.warning, trigger: sosTriggerCount)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Phát tín hiệu khẩn cấp SOS")
            .accessibilityHint("Nhấn và giữ liên tục 1 phẩy 5 giây để phát quảng bá SOS kèm tọa độ GPS")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Phát SOS khẩn cấp ngay") {
                sosTriggerCount += 1
                coordinator.triggerSOS()
            }
        }
    }

    private var sosHoldHintPill: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPressingSOS)) { context in
            let remaining = max(0, Self.sosHoldDuration * (1.0 - holdProgress(at: context.date)))
            HStack(spacing: 6) {
                Image(systemName: "hand.tap.fill")
                    .imageScale(.small)
                Text("Giữ tiếp ")
                    + Text(remaining.formatted(.number.precision(.fractionLength(1))))
                    .monospacedDigit()
                    .bold()
                    + Text("s để phát tín hiệu SOS toàn mạng")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(MeshTheme.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(MeshTheme.sosCrimson.opacity(0.24), in: Capsule())
            .overlay {
                Capsule().strokeBorder(MeshTheme.sosCrimson.opacity(0.55), lineWidth: 0.8)
            }
        }
    }

    private func holdProgress(at date: Date) -> Double {
        guard isPressingSOS, let start = sosPressStartDate else {
            return 0
        }
        let elapsed = date.timeIntervalSince(start)
        return min(1.0, max(0.0, elapsed / Self.sosHoldDuration))
    }

    private func beginSOSHoldIfNeeded() {
        guard !isPressingSOS, !didFireCurrentSOSHold else { return }
        let start = Date()
        sosPressStartDate = start
        isPressingSOS = true

        sosHoldTask?.cancel()
        sosHoldTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, isPressingSOS, sosPressStartDate == start else {
                return
            }
            didFireCurrentSOSHold = true
            isPressingSOS = false
            sosPressStartDate = nil
            sosTriggerCount += 1
            coordinator.triggerSOS()
        }
    }

    private func cancelSOSHold() {
        sosHoldTask?.cancel()
        sosHoldTask = nil
        if isPressingSOS {
            isPressingSOS = false
        }
        sosPressStartDate = nil
        didFireCurrentSOSHold = false
    }
}
#endif
