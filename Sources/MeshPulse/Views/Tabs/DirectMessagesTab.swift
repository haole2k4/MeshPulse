#if canImport(SwiftUI)
import MeshCore
import SwiftUI

/// Tab 3 (`Cá nhân`): End-to-End Encrypted 1-to-1 conversations (`Curve25519` / TOFU key verification)
/// paired with the `DTN Outbox` Store-and-Forward inspector.
public struct DirectMessagesTab: View {
    private enum RootSegment: String, CaseIterable, Identifiable {
        case conversations = "Trò chuyện 1-1"
        case dtnOutbox = "Hộp thư chờ DTN"

        var id: String { rawValue }
    }

    public var coordinator: MeshCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var navigationPath: [String] = []
    @State private var selectedSegment: RootSegment = .conversations

    public init(coordinator: MeshCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                segmentedHeader

                ScrollView {
                    switch selectedSegment {
                    case .conversations:
                        conversationsListSection
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 32)

                    case .dtnOutbox:
                        dtnOutboxSection
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 32)
                    }
                }
            }
            .background(MeshTheme.background)
            .navigationTitle("Cá nhân & DTN")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .navigationDestination(for: String.self) { peerID in
                DirectPeerChatRoomView(coordinator: coordinator, peerID: peerID)
            }
        }
        .onAppear {
            syncPathFromCoordinator()
        }
        .onChange(of: coordinator.selectedDirectPeerID) { _, newPeerID in
            if newPeerID != nil {
                selectedSegment = .conversations
            }
            let desired = newPeerID.map { [$0] } ?? []
            if navigationPath != desired {
                navigationPath = desired
            }
        }
        .onChange(of: navigationPath) { _, newPath in
            let activePeerID = newPath.last
            if coordinator.selectedDirectPeerID != activePeerID {
                coordinator.selectedDirectPeerID = activePeerID
            }
        }
    }

    private func syncPathFromCoordinator() {
        let desired = coordinator.selectedDirectPeerID.map { [$0] } ?? []
        if navigationPath != desired {
            navigationPath = desired
        }
    }

    // MARK: - Root Segmented Control

    private var segmentedHeader: some View {
        VStack(spacing: 8) {
            Picker("Phân mục Cá nhân", selection: $selectedSegment) {
                ForEach(RootSegment.allCases) { segment in
                    if segment == .dtnOutbox && !coordinator.dtnRecords.isEmpty {
                        Text("\(segment.rawValue) (\(coordinator.dtnRecords.count))")
                            .tag(segment)
                    } else {
                        Text(segment.rawValue)
                            .tag(segment)
                    }
                }
            }
            .pickerStyle(.segmented)
            .sensoryFeedback(.selection, trigger: selectedSegment)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background {
            MeshTheme.background.opacity(0.85)
                .background(.ultraThinMaterial)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MeshTheme.hairlineBorder)
                .frame(height: 0.8)
        }
    }

    // MARK: - Segment 1: 1-to-1 Conversations

    private var conversationsListSection: some View {
        let items = coordinator.directConversationPeers
        return VStack(alignment: .leading, spacing: 12) {
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(MeshTheme.p2pGreen)

                    Text("Chưa có trạm để trò chuyện 1-1")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MeshTheme.primaryText)

                    Text("Khi phát hiện thiết bị lân cận hoặc trạm bắc cầu, khóa công khai E2EE sẽ tự động đồng bộ tại đây.")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(26)
                .frame(maxWidth: .infinity)
                .meshCard()
            } else {
                ForEach(items) { peer in
                    NavigationLink(value: peer.id) {
                        conversationRow(peer)
                    }
                    .buttonStyle(.applePressable)
                }
            }
        }
    }

    private func conversationRow(_ peer: PeerSummary) -> some View {
        let thread = coordinator.messages(forPeerID: peer.id)
        let lastMessage = thread.last

        return HStack(alignment: .center, spacing: 12) {
            // Station Avatar with Link indicator
            ZStack {
                Circle()
                    .fill(MeshTheme.elevatedSurface)
                    .frame(width: 44, height: 44)

                Text(String(peer.identity.displayName.prefix(1)).uppercased())
                    .font(.headline.weight(.bold))
                    .foregroundStyle(MeshTheme.color(for: peer.linkKind))

                Circle()
                    .fill(MeshTheme.color(for: peer.linkKind))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(MeshTheme.cardSurface, lineWidth: 2))
                    .offset(x: 15, y: 15)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(peer.identity.displayName)
                        .font(.headline)
                        .foregroundStyle(MeshTheme.primaryText)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    if let lastMessage {
                        Text(lastMessage.timestamp, format: .dateTime.hour().minute())
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(MeshTheme.secondaryText)
                    } else {
                        LinkStatusBadge(linkKind: peer.linkKind)
                    }
                }

                HStack(alignment: .center, spacing: 4) {
                    if let lastMessage {
                        if lastMessage.isEncrypted {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.p2pGreen)
                        }
                        Text(lastMessage.isOutgoing ? "Bạn: \(lastMessage.text)" : lastMessage.text)
                            .font(.subheadline)
                            .foregroundStyle(MeshTheme.secondaryText)
                            .lineLimit(1)
                    } else {
                        Text("Nhắn tin mã hóa E2EE (hỗ trợ DTN ngoại tuyến)")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    if lastMessage != nil {
                        LinkStatusBadge(linkKind: peer.linkKind)
                    }
                }
            }
        }
        .padding(14)
        .meshCard()
        .contentShape(Rectangle())
    }

    // MARK: - Segment 2: DTN Store-and-Forward Outbox

    private var dtnOutboxSection: some View {
        let records = coordinator.dtnRecords
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Chiến lược: \(coordinator.routingStrategy.title)", systemImage: coordinator.routingStrategy.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MeshTheme.dtnIndigo)

                Spacer()

                Text("\(records.count) gói đang chờ")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(MeshTheme.secondaryText)
            }
            .padding(.horizontal, 4)

            if records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(MeshTheme.dtnIndigo)

                    Text("Hộp thư chờ DTN đang trống")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MeshTheme.primaryText)

                    Text("Mọi gói tin chưa có đường tới đích sẽ được giữ an toàn tại đây và tự động chuyển tiếp khi gặp trạm Data Mule.")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(26)
                .frame(maxWidth: .infinity)
                .meshCard()
            } else {
                ForEach(records) { record in
                    dtnRecordCard(record)
                }
            }
        }
    }

    private func dtnRecordCard(_ record: StoredDTNRecord) -> some View {
        let targetPeer = coordinator.peerSummary(for: record.packet.targetID)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: record.packet.isEncrypted ? "lock.fill" : "envelope.fill")
                        .imageScale(.small)
                    Text(record.packet.type.rawValue.uppercased())
                        .font(.caption2.monospaced().weight(.bold))
                }
                .foregroundStyle(MeshTheme.dtnIndigo)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(MeshTheme.dtnIndigo.opacity(0.16), in: Capsule())

                Text("Đích: \(targetPeer.identity.displayName)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MeshTheme.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(record.packet.targetID.prefix(12) + "…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(MeshTheme.secondaryText)
            }

            HStack(spacing: 12) {
                dtnMetricPill(label: "Bản sao", value: "L=\(record.packet.remainingCopies)")
                dtnMetricPill(label: "TTL", value: "\(record.packet.ttl)")
                dtnMetricPill(label: "Đã trao", value: "\(record.forwardedPeers.count) trạm")
            }

            HStack {
                Text("Xếp hàng: ")
                    .font(.caption2)
                    .foregroundStyle(MeshTheme.secondaryText)
                + Text(record.queuedAt, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MeshTheme.primaryText)

                Spacer()

                Text("Hết hạn: ")
                    .font(.caption2)
                    .foregroundStyle(MeshTheme.secondaryText)
                + Text(record.expiresAt, format: .dateTime.hour().minute())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MeshTheme.secondaryText)
            }
        }
        .padding(14)
        .meshCard(borderColor: MeshTheme.dtnIndigo.opacity(0.32))
    }

    private func dtnMetricPill(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .font(.caption2)
                .foregroundStyle(MeshTheme.secondaryText)
            Text(value)
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(MeshTheme.primaryText)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(MeshTheme.elevatedSurface, in: Capsule())
    }
}

// MARK: - 1-to-1 E2EE Chat Room Destination

private struct DirectPeerChatRoomView: View {
    var coordinator: MeshCoordinator
    let peerID: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draftText = ""
    @State private var includeGPS = false
    @State private var isShowingFingerprintSheet = false
    @State private var sendFeedbackCount = 0

    private var peer: PeerSummary {
        coordinator.peerSummary(for: peerID)
    }

    private var messages: [ChatThreadItem] {
        coordinator.messages(forPeerID: peerID)
    }

    var body: some View {
        VStack(spacing: 0) {
            e2eeRouteBanner

            ScrollViewReader { proxy in
                ScrollView {
                    if messages.isEmpty {
                        emptyRoomState
                            .padding(.top, 44)
                            .padding(.horizontal, 20)
                    } else {
                        LazyVStack(spacing: 16) {
                            ForEach(messages) { item in
                                directBubbleRow(item)
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear {
                    scrollToBottom(proxy: proxy, animated: false)
                }
                .onChange(of: messages.count) { _, _ in
                    scrollToBottom(proxy: proxy, animated: !reduceMotion)
                }
            }

            composerBar
        }
        .background(MeshTheme.background)
        .navigationTitle(peer.identity.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingFingerprintSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.shield.fill")
                            .imageScale(.small)
                        Text("E2EE")
                            .font(.caption.monospaced().weight(.bold))
                    }
                    .foregroundStyle(MeshTheme.p2pGreen)
                    .padding(.horizontal, 10)
                    .frame(minWidth: MeshTheme.minTapDimension, minHeight: MeshTheme.minTapDimension)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.applePressable)
                .accessibilityLabel("Đối chiếu vân tay khóa mã hóa đầu cuối")
            }
        }
        .sheet(isPresented: $isShowingFingerprintSheet) {
            KeyFingerprintVerificationSheet(
                localIdentity: coordinator.localIdentity,
                peerIdentity: peer.identity
            )
            .presentationDetents([.medium, .large])
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sendFeedbackCount)
    }

    private var e2eeRouteBanner: some View {
        HStack(spacing: 8) {
            LinkStatusBadge(linkKind: peer.linkKind)

            Spacer(minLength: 6)

            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MeshTheme.p2pGreen)
                Text(
                    peer.identity.publicKeyBase64 != nil
                        ? "E2EE Hoạt động"
                        : "Chờ trao đổi khóa"
                )
                .font(.caption2.weight(.medium))
                .foregroundStyle(MeshTheme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(MeshTheme.cardSurface.opacity(0.85))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MeshTheme.hairlineBorder)
                .frame(height: 0.8)
        }
    }

    private var emptyRoomState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(MeshTheme.p2pGreen)

            Text("Phòng trò chuyện mã hóa đầu-cuối")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MeshTheme.primaryText)

            Text("Nội dung tin nhắn chỉ giải mã được trên thiết bị của bạn và \(peer.identity.displayName). Các trạm bắc cầu trung gian không thể đọc dữ liệu.")
                .font(.caption)
                .foregroundStyle(MeshTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .meshCard()
    }

    private func directBubbleRow(_ item: ChatThreadItem) -> some View {
        VStack(alignment: item.isOutgoing ? .trailing : .leading, spacing: 5) {
            HStack(spacing: 5) {
                if item.isEncrypted {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.p2pGreen)
                }
                Text(item.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MeshTheme.secondaryText)
            }
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(item.text)
                    .font(.body)
                    .foregroundStyle(item.isOutgoing ? Color.white : MeshTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let coord = item.coordinate {
                    GeoLocationLinkChip(
                        coordinate: coord,
                        label: item.senderName,
                        tint: item.isOutgoing ? Color.white : MeshTheme.p2pGreen
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                item.isOutgoing
                    ? AnyShapeStyle(MeshTheme.p2pGreen)
                    : AnyShapeStyle(MeshTheme.cardSurface),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                if !item.isOutgoing {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(MeshTheme.hairlineBorder, lineWidth: 0.8)
                }
            }
            .frame(maxWidth: 320, alignment: item.isOutgoing ? .trailing : .leading)

            HopPathBadge(
                routeNames: item.routeNames,
                hopCount: item.hopCount,
                deliveryState: item.isOutgoing ? item.deliveryState : nil,
                rttMs: item.rttMs
            )
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: item.isOutgoing ? .trailing : .leading)
    }

    private var composerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if includeGPS {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                        .font(.caption2.weight(.bold))
                    Text("Đính kèm tọa độ GPS được mã hóa cùng gói tin")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(MeshTheme.p2pGreen)
                .padding(.horizontal, 6)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                        includeGPS.toggle()
                    }
                } label: {
                    Image(systemName: includeGPS ? "location.fill" : "location")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(includeGPS ? MeshTheme.p2pGreen : MeshTheme.secondaryText)
                        .frame(width: MeshTheme.minTapDimension, height: MeshTheme.minTapDimension)
                        .background(
                            includeGPS ? MeshTheme.p2pGreen.opacity(0.16) : MeshTheme.elevatedSurface,
                            in: Circle()
                        )
                        .overlay {
                            Circle().strokeBorder(
                                includeGPS ? MeshTheme.p2pGreen.opacity(0.45) : MeshTheme.hairlineBorder,
                                lineWidth: 0.8
                            )
                        }
                }
                .buttonStyle(.applePressable)
                .sensoryFeedback(.selection, trigger: includeGPS)
                .accessibilityLabel(includeGPS ? "Đã bật đính kèm vị trí GPS" : "Đính kèm vị trí GPS")

                TextField("Nhắn mã hóa tới \(peer.identity.displayName)...", text: $draftText, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.body)
                    .foregroundStyle(MeshTheme.primaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: MeshTheme.minTapDimension)
                    .background(MeshTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(MeshTheme.hairlineBorder, lineWidth: 0.8)
                    }

                Button {
                    submitDirectMessage()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(canSend ? Color.white : MeshTheme.secondaryText)
                        .frame(width: 36, height: 36)
                        .background(canSend ? MeshTheme.p2pGreen : MeshTheme.elevatedSurface, in: Circle())
                }
                .buttonStyle(.applePressable)
                .disabled(!canSend)
                .padding(.bottom, 4)
                .accessibilityLabel("Gửi tin nhắn mã hóa")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            MeshTheme.background.opacity(0.85)
                .background(.ultraThinMaterial)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MeshTheme.hairlineBorder)
                .frame(height: 0.8)
        }
    }

    private var canSend: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || includeGPS
    }

    private func submitDirectMessage() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalBody = trimmed.isEmpty && includeGPS ? "Chia sẻ tọa độ GPS ngoại tuyến." : trimmed
        guard !finalBody.isEmpty else { return }

        sendFeedbackCount += 1
        coordinator.sendDirectMessage(to: peerID, text: finalBody, includeLocation: includeGPS)
        draftText = ""
        includeGPS = false
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard let lastID = messages.last?.id else { return }
        if animated {
            withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

// MARK: - Key Fingerprint Verification Sheet

private struct KeyFingerprintVerificationSheet: View {
    let localIdentity: NodeIdentity
    let peerIdentity: NodeIdentity

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fingerprintCard(
                        roleTitle: "Thiết bị này (Bạn)",
                        identity: localIdentity,
                        accent: MeshTheme.p2pGreen
                    )

                    fingerprintCard(
                        roleTitle: "Đối tác trò chuyện",
                        identity: peerIdentity,
                        accent: MeshTheme.meshAmber
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Cơ chế Bảo mật Xuyên Trạm & TOFU", systemImage: "checkmark.shield.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MeshTheme.p2pGreen)

                        Text("MeshPulse ghim khóa công khai lần đầu (Trust On First Use) theo NodeID và niêm phong tải tin bằng khóa thỏa thuận đầu-cuối. Ngay cả khi gói tin đi bắc cầu qua nhiều iPhone trung gian hoặc nằm trong DTN Outbox, các nút chuyển tiếp chỉ thấy bản mã mù và không thể đọc hay sửa đổi nội dung.")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.secondaryText)
                    }
                    .padding(14)
                    .meshCard()
                }
                .padding(16)
            }
            .background(MeshTheme.background)
            .navigationTitle("Xác minh Khóa E2EE")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") {
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                    .frame(minWidth: MeshTheme.minTapDimension, minHeight: MeshTheme.minTapDimension)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func fingerprintCard(
        roleTitle: String,
        identity: NodeIdentity,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(roleTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)

            HStack {
                Text(identity.displayName)
                    .font(.headline)
                    .foregroundStyle(MeshTheme.primaryText)
                Spacer()
                Text(identity.nodeID.prefix(12) + "…")
                    .font(.caption.monospaced())
                    .foregroundStyle(MeshTheme.secondaryText)
            }

            Text(identity.publicKeyFingerprint ?? "Chưa nhận được khóa công khai")
                .font(.subheadline.monospaced().weight(.bold))
                .foregroundStyle(MeshTheme.primaryText)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MeshTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(14)
        .meshCard()
    }
}
#endif
