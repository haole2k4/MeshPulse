#if canImport(SwiftUI)
import MeshCore
import SwiftUI

/// Persistent tactical top status bar with 1-tap Radio toggle, editable Display Name,
/// and 1.5-second continuous hold-to-trigger SOS Signal button.
public struct TopStatusHeader: View {
    private static let sosHoldDuration: TimeInterval = 1.5

    public var coordinator: MeshCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            HStack(spacing: 10) {
                radioStatusButton
                Spacer(minLength: 4)
                deviceIdentityButton
                Spacer(minLength: 4)
                sosHoldButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                MeshTheme.background.opacity(0.92)
                    .background(.ultraThinMaterial)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(MeshTheme.hairlineBorder)
                    .frame(height: 1)
            }

            if isPressingSOS {
                sosHoldHintPill
                    .padding(.horizontal, 12)
                    .transition(.opacity)
            }

            if let sosBanner = coordinator.activeSOSBanner {
                emergencySOSBanner(sosBanner)
                    .padding(.horizontal, 12)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
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

    // MARK: - Left: Radio & Link Counts Pill

    private var radioStatusButton: some View {
        Button {
            withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                coordinator.toggleRadio()
            }
        } label: {
            HStack(spacing: 7) {
                if coordinator.isRadioEnabled {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(MeshTheme.p2pGreen)
                            .frame(width: 7, height: 7)
                        Text("\(coordinator.directP2PCount)")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(MeshTheme.primaryText)
                        Text("P2P")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(MeshTheme.secondaryText)
                    }

                    Rectangle()
                        .fill(MeshTheme.hairlineBorder)
                        .frame(width: 1, height: 12)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(MeshTheme.meshAmber)
                            .frame(width: 7, height: 7)
                        Text("\(coordinator.meshRelayedCount)")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(MeshTheme.primaryText)
                        Text("Mesh")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(MeshTheme.secondaryText)
                    }
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .imageScale(.small)
                        .foregroundStyle(MeshTheme.sosCrimson)
                    Text("Tắt sóng")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MeshTheme.sosCrimson)
                }

                if coordinator.isMockMode {
                    Text("SIM")
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(MeshTheme.dtnIndigo)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(MeshTheme.dtnIndigo.opacity(0.16), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(minWidth: MeshTheme.minTapDimension, minHeight: MeshTheme.minTapDimension)
            .background(MeshTheme.cardSurface, in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    coordinator.isRadioEnabled ? MeshTheme.hairlineBorder : MeshTheme.sosCrimson.opacity(0.45),
                    lineWidth: 1
                )
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: coordinator.isRadioEnabled)
        .accessibilityLabel(
            coordinator.isRadioEnabled
                ? "Sóng đang bật: \(coordinator.directP2PCount) kết nối trực tiếp, \(coordinator.meshRelayedCount) kết nối bắc cầu"
                : "Sóng ngoại tuyến đang tắt"
        )
        .accessibilityHint("Chạm để bật hoặc tắt nhanh sóng mạng lưới")
    }

    // MARK: - Center: Editable Local Node Identity

    private var deviceIdentityButton: some View {
        Button {
            draftDisplayName = coordinator.localDisplayName
            isShowingRenameAlert = true
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text(coordinator.localDisplayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MeshTheme.primaryText)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MeshTheme.secondaryText)
                }
                Text(coordinator.localNodeID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(MeshTheme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: MeshTheme.minTapDimension)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Thiết bị hiện tại: \(coordinator.localDisplayName), mã nút \(coordinator.localNodeID)")
        .accessibilityHint("Chạm để đổi tên hiển thị")
    }

    // MARK: - Right: 1.5s Hold-to-Trigger SOS Control

    private var sosHoldButton: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPressingSOS)) { context in
            let progress = holdProgress(at: context.date)

            ZStack {
                Circle()
                    .fill(
                        isPressingSOS
                            ? MeshTheme.sosCrimson.opacity(0.28)
                            : MeshTheme.sosCrimson.opacity(0.15)
                    )

                Circle()
                    .strokeBorder(MeshTheme.sosCrimson.opacity(0.38), lineWidth: 1.5)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        MeshTheme.sosCrimson,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .padding(1.5)

                VStack(spacing: 1) {
                    Image(systemName: "light.beacon.max.fill")
                        .font(.caption.weight(.bold))
                    Text("SOS")
                        .font(.caption2.monospaced().weight(.bold))
                }
                .foregroundStyle(MeshTheme.sosCrimson)
            }
            .frame(width: 46, height: 46)
            .scaleEffect(isPressingSOS && !reduceMotion ? 0.94 : 1.0)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = value.location.x - 23
                        let dy = value.location.y - 23
                        if hypot(dx, dy) > 56 {
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
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(MeshTheme.sosCrimson.opacity(0.22), in: Capsule())
            .overlay {
                Capsule().strokeBorder(MeshTheme.sosCrimson.opacity(0.5), lineWidth: 1)
            }
        }
    }

    // MARK: - Active SOS Signal Alert Banner

    private func emergencySOSBanner(_ item: ChatThreadItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "light.beacon.max.fill")
                .font(.headline)
                .foregroundStyle(MeshTheme.sosCrimson)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.isOutgoing ? "Đã phát tín hiệu SOS" : "SOS từ \(item.senderName)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(MeshTheme.primaryText)
                    Text("\(item.hopCount)H")
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(MeshTheme.sosCrimson)
                }

                Text(item.text)
                    .font(.caption)
                    .foregroundStyle(MeshTheme.primaryText.opacity(0.9))
                    .lineLimit(2)

                if let coord = item.coordinate {
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill")
                            .imageScale(.small)
                        Text(formatCoordinate(coord))
                            .font(.caption2.monospaced())
                    }
                    .foregroundStyle(MeshTheme.badgeText)
                }
            }

            Spacer(minLength: 4)

            Button {
                withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                    coordinator.selectedTab = .broadcast
                    coordinator.dismissSOSBanner()
                }
            } label: {
                Text("Mở")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(MeshTheme.primaryText)
                    .padding(.horizontal, 10)
                    .frame(minHeight: MeshTheme.minTapDimension)
                    .background(MeshTheme.sosCrimson.opacity(0.32), in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                    coordinator.dismissSOSBanner()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(MeshTheme.secondaryText)
                    .frame(width: MeshTheme.minTapDimension, height: MeshTheme.minTapDimension)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Đóng cảnh báo SOS")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(
            MeshTheme.sosCrimson.opacity(0.14),
            in: RoundedRectangle(cornerRadius: MeshTheme.cardCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: MeshTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(MeshTheme.sosCrimson.opacity(0.55), lineWidth: 1)
        }
    }

    // MARK: - SOS Hold Helpers

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

    private func formatCoordinate(_ coord: GeoCoordinate) -> String {
        let lat = coord.latitude.formatted(.number.precision(.fractionLength(5)))
        let lon = coord.longitude.formatted(.number.precision(.fractionLength(5)))
        let acc = Int(coord.accuracyMeters.rounded())
        return "\(lat), \(lon) (±\(acc)m)"
    }
}
#endif
