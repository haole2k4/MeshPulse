#if canImport(SwiftUI)
import MeshCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Tab 3 (`Tin nhắn / Messages`): Unified Messaging tab per UIplan.md & Apple Native standards:
/// - Root hub lists featured Broadcast Channel (`Kênh Chung`) and 1-to-1 E2EE Chats (`Trò chuyện 1-1`)
/// - Clean segmented filter (`Hội thoại`, `Trò chuyện 1-1`, `Chờ DTN`)
/// - Tapping any conversation pushes into a dedicated full-screen Chat Room where Floating Glass TabBar is 100% hidden
/// - Composer bar sits cleanly at the bottom without ever being overlapped by navigation or tab bars
public struct MessagesTab: View {
    public enum MessageSegment: String, CaseIterable, Identifiable {
        case all = "Hội thoại"
        case direct = "Trò chuyện 1-1"
        case dtn = "Chờ DTN"

        public var id: String { rawValue }
    }

    public enum ChatDestination: Hashable {
        case broadcast
        case direct(String)
    }

    public var coordinator: MeshCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedSegment: MessageSegment = .all
    @State private var navigationPath: [ChatDestination] = []

    public init(coordinator: MeshCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                // Segmented control header
                segmentedHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                // Segment content
                Group {
                    switch selectedSegment {
                    case .all:
                        conversationsHubView
                    case .direct:
                        directOnlyListView
                    case .dtn:
                        DTNOutboxView(coordinator: coordinator)
                    }
                }
            }
            .background(MeshTheme.background)
            .navigationTitle("Tin nhắn")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(coordinator.isRadioEnabled ? MeshTheme.emerald : MeshTheme.sosCrimson)
                            .frame(width: 7, height: 7)
                        Text("\(coordinator.directP2PCount) P2P • \(coordinator.meshRelayedCount) Mesh")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(MeshTheme.secondaryText)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(MeshTheme.cardSurface, in: Capsule())
                }

                if coordinator.activeSOSBanner != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            coordinator.dismissSOSBanner()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "light.beacon.max.fill")
                                Text("SOS")
                            }
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(MeshTheme.sosCrimson, in: Capsule())
                        }
                    }
                }
            }
            .navigationDestination(for: ChatDestination.self) { destination in
                switch destination {
                case .broadcast:
                    BroadcastChatRoomView(coordinator: coordinator, navigationPath: $navigationPath)
                case let .direct(peerID):
                    DirectPeerChatRoomView(coordinator: coordinator, peerID: peerID, navigationPath: $navigationPath)
                }
            }
        }
        .onAppear {
            if let id = coordinator.selectedDirectPeerID {
                selectedSegment = .all
                if navigationPath.last != .direct(id) {
                    navigationPath = [.direct(id)]
                }
            } else if !navigationPath.isEmpty {
                coordinator.isChatActive = true
            } else {
                coordinator.isChatActive = false
            }
        }
        .onChange(of: coordinator.selectedDirectPeerID) { _, newPeerID in
            if let id = newPeerID {
                selectedSegment = .all
                if navigationPath.last != .direct(id) {
                    navigationPath = [.direct(id)]
                }
            }
        }
        .onChange(of: navigationPath) { _, newPath in
            let inChat = !newPath.isEmpty
            coordinator.isChatActive = inChat
            if case let .direct(peerID)? = newPath.last {
                coordinator.selectedDirectPeerID = peerID
            } else {
                coordinator.selectedDirectPeerID = nil
            }
        }
    }

    // MARK: - Segmented Header

    private var segmentedHeader: some View {
        Picker("Phân mục tin nhắn", selection: $selectedSegment) {
            ForEach(MessageSegment.allCases) { segment in
                if segment == .dtn && !coordinator.dtnRecords.isEmpty {
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

    // MARK: - Conversations Hub (All)

    private var conversationsHubView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Featured Channel Card: Kênh Chung
                VStack(alignment: .leading, spacing: 8) {
                    Text("KÊNH QUẢNG BÁ")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(MeshTheme.secondaryText)
                        .padding(.horizontal, 4)

                    broadcastChannelCard
                }

                // Section: 1-to-1 Direct E2EE Chats
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("TRÒ CHUYỆN 1-1 (E2EE)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(MeshTheme.secondaryText)

                        Spacer()

                        Text("\(coordinator.directConversationPeers.count) trạm")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(MeshTheme.secondaryText)
                    }
                    .padding(.horizontal, 4)

                    if coordinator.directConversationPeers.isEmpty {
                        emptyDirectState
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(coordinator.directConversationPeers.enumerated()), id: \.element.id) { idx, peer in
                                directConversationRow(peer)

                                if idx < coordinator.directConversationPeers.count - 1 {
                                    Divider()
                                        .overlay(MeshTheme.hairlineBorder)
                                        .padding(.leading, 68)
                                }
                            }
                        }
                        .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 96)
        }
    }

    // MARK: - Direct Only List

    private var directOnlyListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if coordinator.directConversationPeers.isEmpty {
                    emptyDirectState
                        .padding(.top, 40)
                        .padding(.horizontal, 16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(coordinator.directConversationPeers.enumerated()), id: \.element.id) { idx, peer in
                            directConversationRow(peer)

                            if idx < coordinator.directConversationPeers.count - 1 {
                                Divider()
                                    .overlay(MeshTheme.hairlineBorder)
                                    .padding(.leading, 68)
                            }
                        }
                    }
                    .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 96)
        }
    }

    // MARK: - Featured Broadcast Card

    private var broadcastChannelCard: some View {
        let lastMsg = coordinator.broadcastMessages.last
        return Button {
            coordinator.isChatActive = true
            navigationPath.append(.broadcast)
        } label: {
            HStack(spacing: 14) {
                // Broadcast Icon Pill
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(MeshTheme.emerald.opacity(0.18))
                        .frame(width: 48, height: 48)

                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(MeshTheme.emerald)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Kênh Chung (Broadcast)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(MeshTheme.primaryText)

                        Spacer()

                        if let date = lastMsg?.timestamp {
                            Text(date, format: .dateTime.hour().minute())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(MeshTheme.secondaryText)
                        }
                    }

                    HStack(spacing: 4) {
                        if let last = lastMsg {
                            Text(last.isOutgoing ? "Bạn:" : "\(last.senderName):")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(last.isOutgoing ? MeshTheme.emerald : MeshTheme.secondaryText)

                            Text(last.text)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(MeshTheme.secondaryText)
                                .lineLimit(1)
                        } else {
                            Text("Phát quảng bá toàn mạng • Không cần Internet")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(MeshTheme.secondaryText.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MeshTheme.secondaryText.opacity(0.5))
            }
            .padding(14)
            .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Direct Conversation Row

    private func directConversationRow(_ peer: PeerSummary) -> some View {
        let threadItems = coordinator.directThreads[peer.id] ?? []
        let lastItem = threadItems.last

        return Button {
            coordinator.selectedDirectPeerID = peer.id
            coordinator.isChatActive = true
            navigationPath.append(.direct(peer.id))
        } label: {
            HStack(spacing: 12) {
                // Monogram Avatar
                ZStack {
                    Circle()
                        .fill(MeshTheme.emerald.opacity(0.18))
                        .frame(width: 44, height: 44)

                    Text(String(peer.identity.displayName.prefix(2)).uppercased())
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(MeshTheme.emerald)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(peer.identity.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(MeshTheme.primaryText)
                            .lineLimit(1)

                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(MeshTheme.emerald)

                        Spacer()

                        if let date = lastItem?.timestamp {
                            Text(date, format: .dateTime.hour().minute())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(MeshTheme.secondaryText)
                        }
                    }

                    HStack(spacing: 4) {
                        Text(peerRouteText(for: peer))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MeshTheme.emerald)

                        Text("•")
                            .font(.system(size: 12))
                            .foregroundStyle(MeshTheme.secondaryText.opacity(0.5))

                        Text(lastItem?.text ?? "Chưa có tin nhắn")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(lastItem != nil ? MeshTheme.secondaryText : MeshTheme.secondaryText.opacity(0.6))
                            .lineLimit(1)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MeshTheme.secondaryText.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func peerRouteText(for peer: PeerSummary) -> String {
        switch peer.linkKind {
        case .directP2P:
            return "1-Hop P2P"
        case let .relayedMesh(_, _, hops):
            return "\(hops)-Hop"
        case .offlineDTN:
            return "DTN"
        }
    }

    private var emptyDirectState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(MeshTheme.emerald)

            Text("Chưa có cuộc trò chuyện 1-1")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(MeshTheme.primaryText)

            Text("Vào tab Trạm Mạng, chọn một trạm và nhấn Nhắn tin để bắt đầu trò chuyện mã hóa đầu-cuối.")
                .font(.caption)
                .foregroundStyle(MeshTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Advanced Multimedia & CRDT Subcomponents

public struct VoiceNoteBubble: View {
    public let voiceNote: VoiceNotePayload
    public let itemID: UUID
    public let isOutgoing: Bool
    private var voiceService: VoiceNoteService { VoiceNoteService.shared }

    private var isThisPlaying: Bool {
        voiceService.playingID == itemID && voiceService.isPlaying
    }

    private var currentProgress: Double {
        voiceService.playingID == itemID ? voiceService.playbackProgress : 0.0
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // Play / Pause Circle
                Button {
                    voiceService.play(voiceNote: voiceNote, itemID: itemID)
                } label: {
                    ZStack {
                        Circle()
                            .fill(isOutgoing ? Color.white : MeshTheme.emerald)
                            .frame(width: 36, height: 36)

                        Image(systemName: isThisPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(isOutgoing ? MeshTheme.emerald : Color.black)
                            .offset(x: isThisPlaying ? 0 : 1)
                    }
                }
                .buttonStyle(.plain)

                // 24 Waveform Bars
                HStack(alignment: .center, spacing: 2.5) {
                    let samples = voiceNote.waveformSamples.isEmpty
                        ? Array(repeating: Float(0.3), count: 24)
                        : voiceNote.waveformSamples

                    ForEach(samples.indices, id: \.self) { idx in
                        let normalizedProgress = Double(idx) / Double(samples.count)
                        let isPlayed = normalizedProgress <= currentProgress
                        let sampleHeight = CGFloat(max(0.18, min(1.0, samples[idx]))) * 26.0

                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(
                                isOutgoing
                                    ? (isPlayed ? Color.white : Color.white.opacity(0.35))
                                    : (isPlayed ? MeshTheme.emerald : Color.white.opacity(0.2))
                            )
                            .frame(width: 3, height: sampleHeight)
                    }
                }
                .frame(height: 32)

                // Duration Text
                Text(String(format: "0:%02d", Int(round(voiceNote.durationSeconds))))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isOutgoing ? Color.white.opacity(0.9) : MeshTheme.secondaryText)
            }

            // On-Device AI Speech Transcript
            if !voiceNote.transcription.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 9))
                        .foregroundStyle(isOutgoing ? Color.white.opacity(0.7) : MeshTheme.emerald)
                        .padding(.top, 2)

                    Text(voiceNote.transcription)
                        .font(.footnote)
                        .italic()
                        .foregroundStyle(isOutgoing ? Color.white : MeshTheme.primaryText)
                        .lineLimit(3)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            isOutgoing ? MeshTheme.emerald : MeshTheme.cardSurface,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}

public struct MediaImageBubble: View {
    public let item: ChatThreadItem
    public let isOutgoing: Bool

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                #if canImport(UIKit)
                if let data = item.mediaData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 240, maxHeight: 180)
                        .clipped()
                        .cornerRadius(14)
                } else {
                    placeholderView
                }
                #else
                placeholderView
                #endif

                // In-transit chunk download progress overlay
                if !item.isMediaComplete {
                    ZStack {
                        Color.black.opacity(0.65)
                            .cornerRadius(14)

                        VStack(spacing: 8) {
                            ProgressView()
                                .tint(MeshTheme.emerald)
                            let rec = item.mediaReceivedChunks ?? 0
                            let tot = item.mediaTotalChunks ?? 1
                            let pct = tot > 0 ? Int(Double(rec) / Double(tot) * 100) : 0
                            Text("Đang nhận mảnh \(rec)/\(tot) (\(pct)%)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.white)
                        }
                    }
                    .frame(maxWidth: 240, maxHeight: 180)
                }
            }

            if !item.text.isEmpty && item.text != "📷 Hình ảnh Mesh" {
                Text(item.text)
                    .font(.footnote)
                    .foregroundStyle(isOutgoing ? Color.white : MeshTheme.primaryText)
                    .padding(.horizontal, 4)
            }
        }
        .padding(6)
        .background(
            isOutgoing ? MeshTheme.emerald : MeshTheme.cardSurface,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private var placeholderView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(MeshTheme.cardBackground)
                .frame(width: 220, height: 140)

            VStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 32))
                    .foregroundStyle(MeshTheme.secondaryText)
                Text("Ảnh nén Mesh (16KB/chunk)")
                    .font(.caption2)
                    .foregroundStyle(MeshTheme.secondaryText)
            }
        }
    }
}

public struct SmartComposerBar: View {
    public let isBroadcast: Bool
    public let recipientName: String?
    public let onSendText: (String, Bool) -> Void
    public let onSendVoice: (VoiceNotePayload) -> Void
    public let onSendMedia: (Data, String) -> Void
    public let onTriggerRollCall: (() -> Void)?
    public let onTriggerPoll: (() -> Void)?

    @State private var draftText: String = ""
    @State private var includeGPS: Bool = false
    @State private var isRecording: Bool = false
    private var voiceService: VoiceNoteService { VoiceNoteService.shared }

    public init(
        isBroadcast: Bool,
        recipientName: String? = nil,
        onSendText: @escaping (String, Bool) -> Void,
        onSendVoice: @escaping (VoiceNotePayload) -> Void,
        onSendMedia: @escaping (Data, String) -> Void,
        onTriggerRollCall: (() -> Void)? = nil,
        onTriggerPoll: (() -> Void)? = nil
    ) {
        self.isBroadcast = isBroadcast
        self.recipientName = recipientName
        self.onSendText = onSendText
        self.onSendVoice = onSendVoice
        self.onSendMedia = onSendMedia
        self.onTriggerRollCall = onTriggerRollCall
        self.onTriggerPoll = onTriggerPoll
    }

    public var body: some View {
        VStack(spacing: 6) {
            // Live voice recording banner
            if isRecording {
                HStack(spacing: 12) {
                    Circle()
                        .fill(MeshTheme.sosCrimson)
                        .frame(width: 10, height: 10)

                    Text(String(format: "0:%02d", Int(voiceService.recordingDuration)))
                        .font(.subheadline.monospacedDigit().weight(.bold))
                        .foregroundStyle(MeshTheme.sosCrimson)

                    // Live Waveform Mini
                    HStack(spacing: 2) {
                        ForEach(Array(voiceService.liveWaveform.suffix(16).enumerated()), id: \.offset) { _, val in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(MeshTheme.sosCrimson.opacity(0.85))
                                .frame(width: 2.5, height: CGFloat(max(0.2, val)) * 16)
                        }
                    }
                    .frame(height: 18)

                    if !voiceService.liveTranscription.isEmpty {
                        Text(voiceService.liveTranscription)
                            .font(.caption2)
                            .italic()
                            .foregroundStyle(MeshTheme.primaryText)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Cancel
                    Button {
                        voiceService.cancelRecording()
                        isRecording = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(MeshTheme.secondaryText)
                    }

                    // Stop & Send
                    Button {
                        Task {
                            if let payload = await voiceService.stopRecording() {
                                onSendVoice(payload)
                            }
                            isRecording = false
                        }
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(MeshTheme.emerald)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(MeshTheme.cardBackground, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // GPS indicator chip
            if includeGPS {
                HStack(spacing: 5) {
                    Image(systemName: "location.fill")
                        .font(.caption2.weight(.bold))
                    Text("Đính kèm tọa độ GPS vào bản tin")
                        .font(.caption2.weight(.medium))
                    Spacer()
                    Button {
                        includeGPS = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                    }
                }
                .foregroundStyle(MeshTheme.emerald)
                .padding(.horizontal, 14)
            }

            // Main input row
            HStack(alignment: .center, spacing: 10) {
                // [+] Action Menu
                Menu {
                    Button {
                        includeGPS.toggle()
                    } label: {
                        Label(includeGPS ? "Bỏ đính kèm GPS" : "Đính kèm Tọa độ GPS", systemImage: "location.fill")
                    }

                    if isBroadcast {
                        Button {
                            onTriggerRollCall?()
                        } label: {
                            Label("Điểm danh An toàn (Roll Call)", systemImage: "shield.checkered")
                        }

                        Button {
                            onTriggerPoll?()
                        } label: {
                            Label("Tạo Bình chọn Nhanh (Poll)", systemImage: "chart.bar.xaxis")
                        }
                    }

                    Button {
                        sendMockCompressedPhoto()
                    } label: {
                        Label("Gửi Ảnh Nén Mesh (16KB/chunk)", systemImage: "photo.fill")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(includeGPS ? MeshTheme.emerald : MeshTheme.secondaryText)
                }

                // Text field
                TextField(
                    isBroadcast ? "Gửi tin nhắn tới toàn mạng..." : "Nhắn mã hóa tới \(recipientName ?? "trạm")...",
                    text: $draftText,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .font(.body)
                .foregroundStyle(MeshTheme.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(minHeight: 38)
                .background(MeshTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 19, style: .continuous))

                // Dynamic Action Button (Mic vs Send)
                if canSendText {
                    Button {
                        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let body = text.isEmpty && includeGPS ? "Chia sẻ tọa độ GPS ngoại tuyến." : text
                        onSendText(body, includeGPS)
                        draftText = ""
                        includeGPS = false
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(MeshTheme.emerald)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                } else {
                    // Push to talk button
                    Button {
                        if !isRecording {
                            Task {
                                isRecording = await voiceService.startRecording()
                            }
                        } else {
                            Task {
                                if let payload = await voiceService.stopRecording() {
                                    onSendVoice(payload)
                                }
                                isRecording = false
                            }
                        }
                    } label: {
                        Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(isRecording ? MeshTheme.sosCrimson : MeshTheme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }

    private var canSendText: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || includeGPS
    }

    private func sendMockCompressedPhoto() {
        #if canImport(UIKit)
        let size = CGSize(width: 400, height: 300)
        let renderer = UIGraphicsImageRenderer(size: size)
        let testImage = renderer.image { ctx in
            UIColor(red: 0.07, green: 0.12, blue: 0.15, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let title = "MeshPulse Tactical Image"
            let subtitle = "16KB Multi-Hop Chunked Transfer"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 20),
                .foregroundColor: UIColor(red: 0.06, green: 0.72, blue: 0.51, alpha: 1.0)
            ]
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.white
            ]
            (title as NSString).draw(at: CGPoint(x: 24, y: 120), withAttributes: attrs)
            (subtitle as NSString).draw(at: CGPoint(x: 24, y: 155), withAttributes: subAttrs)
        }
        if let jpeg = testImage.jpegData(compressionQuality: 0.4) {
            onSendMedia(jpeg, "Ảnh chụp vệ tinh dã chiến (Mesh)")
            return
        }
        #endif
        let dummy = Data("MOCK_JPEG_PAYLOAD".utf8)
        onSendMedia(dummy, "Ảnh kiểm tra Mesh")
    }
}

// Quick sheet for creating a Roll Call
struct CreateRollCallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String = "Khẩn cấp: Xác nhận an toàn sau sự cố"
    let onConfirm: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Tiêu đề đợt điểm danh") {
                    TextField("Nội dung điểm danh", text: $title)
                }
                Section {
                    Button("Phát Điểm Danh Toàn Mạng (CRDT)") {
                        onConfirm(title)
                        dismiss()
                    }
                    .foregroundStyle(MeshTheme.emerald)
                    .fontWeight(.bold)
                }
            }
            .navigationTitle("Điểm Danh An Toàn")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// Quick sheet for creating a Poll
struct CreatePollSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var question: String = "Đoàn mình nên di chuyển đến địa điểm nào?"
    @State private var opt1: String = "Trạm y tế A"
    @State private var opt2: String = "Khu tập kết B"
    @State private var opt3: String = "Ở lại cố thủ C"
    let onConfirm: (String, [String]) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Câu hỏi bình chọn") {
                    TextField("Câu hỏi", text: $question)
                }
                Section("Các lựa chọn") {
                    TextField("Phương án 1", text: $opt1)
                    TextField("Phương án 2", text: $opt2)
                    TextField("Phương án 3", text: $opt3)
                }
                Section {
                    Button("Phát Bình Chọn Toàn Mạng (CRDT)") {
                        let opts = [opt1, opt2, opt3].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        onConfirm(question, opts)
                        dismiss()
                    }
                    .foregroundStyle(MeshTheme.meshCyan)
                    .fontWeight(.bold)
                }
            }
            .navigationTitle("Bình Chọn Nhanh")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - 1. Broadcast Chat Room View (Kênh Chung)

public struct BroadcastChatRoomView: View {
    public var coordinator: MeshCoordinator
    public var navigationPath: Binding<[MessagesTab.ChatDestination]>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sendFeedbackCount = 0
    @State private var isShowingCreateRollCall = false
    @State private var isShowingCreatePoll = false

    public init(coordinator: MeshCoordinator, navigationPath: Binding<[MessagesTab.ChatDestination]>? = nil) {
        self.coordinator = coordinator
        self.navigationPath = navigationPath
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Channel banner
            channelBanner

            // Pinned Interactive CRDT Roll Call & Poll Card
            PinnedCRDTHeaderView(
                localNodeID: coordinator.localNodeID,
                rollCall: coordinator.activeRollCall,
                poll: coordinator.activePoll,
                onVoteRollCall: { status in
                    coordinator.voteRollCall(status: status)
                },
                onVotePoll: { optionIndex in
                    coordinator.votePoll(optionIndex: optionIndex)
                },
                onDismissRollCall: {
                    coordinator.dismissRollCall()
                },
                onDismissPoll: {
                    coordinator.dismissPoll()
                }
            )

            // Message stream
            ScrollViewReader { proxy in
                ScrollView {
                    if coordinator.broadcastMessages.isEmpty {
                        emptyBroadcastState
                            .padding(.top, 40)
                            .padding(.horizontal, 20)
                    } else {
                        LazyVStack(spacing: 14) {
                            ForEach(coordinator.broadcastMessages) { item in
                                if item.isSOS {
                                    sosBroadcastCard(item)
                                        .id(item.id)
                                } else {
                                    broadcastMessageRow(item)
                                        .id(item.id)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear {
                    scrollToBottom(proxy: proxy, animated: false)
                }
                .onChange(of: coordinator.broadcastMessages.count) { _, _ in
                    scrollToBottom(proxy: proxy, animated: !reduceMotion)
                }
            }

            // Smart Composer Bar
            SmartComposerBar(
                isBroadcast: true,
                recipientName: nil,
                onSendText: { text, gps in
                    sendFeedbackCount += 1
                    coordinator.sendBroadcast(text: text, includeLocation: gps)
                },
                onSendVoice: { vn in
                    sendFeedbackCount += 1
                    coordinator.sendVoiceNote(voiceNote: vn, to: MeshPacket.broadcastTarget)
                },
                onSendMedia: { data, caption in
                    sendFeedbackCount += 1
                    coordinator.sendMedia(data: data, caption: caption, to: MeshPacket.broadcastTarget)
                },
                onTriggerRollCall: {
                    isShowingCreateRollCall = true
                },
                onTriggerPoll: {
                    isShowingCreatePoll = true
                }
            )
        }
        .background(MeshTheme.background)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("Kênh Chung (Broadcast)")
                        .font(.headline)
                        .foregroundStyle(MeshTheme.primaryText)
                    Text("Phát toàn mạng • \(coordinator.directP2PCount) P2P, \(coordinator.meshRelayedCount) Mesh")
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.secondaryText)
                }
            }
        }
        .onAppear {
            coordinator.isChatActive = true
        }
        .onDisappear {
            if navigationPath?.wrappedValue.isEmpty ?? true {
                coordinator.isChatActive = false
            }
        }
        .sheet(isPresented: $isShowingCreateRollCall) {
            CreateRollCallSheet { title in
                coordinator.broadcastRollCall(title: title)
            }
        }
        .sheet(isPresented: $isShowingCreatePoll) {
            CreatePollSheet { question, options in
                coordinator.broadcastPoll(question: question, options: options)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sendFeedbackCount)
    }

    private var channelBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(MeshTheme.emerald)

            Text("Phát quảng bá toàn mạng · Mọi trạm lân cận đều nhận")
                .font(.caption2.weight(.medium))
                .foregroundStyle(MeshTheme.secondaryText)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(MeshTheme.cardSurface)
    }

    private var emptyBroadcastState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(MeshTheme.secondaryText)

            Text("Chưa có tin nhắn Kênh Chung")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(MeshTheme.primaryText)

            Text("Tin nhắn gửi tại đây sẽ lan tỏa qua nhiều bước nhảy ngoại tuyến tới mọi thiết bị trong mạng.")
                .font(.caption)
                .foregroundStyle(MeshTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func broadcastMessageRow(_ item: ChatThreadItem) -> some View {
        VStack(alignment: item.isOutgoing ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 6) {
                if item.isOutgoing {
                    Text("Bạn (\(item.senderName))")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(MeshTheme.emerald)
                } else {
                    Text(item.senderName)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(MeshTheme.primaryText)
                }

                Text(item.timestamp, format: .dateTime.hour().minute())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MeshTheme.secondaryText)
            }
            .padding(.horizontal, 4)

            // Dynamic Bubble (Voice / Media Image / Text)
            if let vn = item.voiceNote {
                VoiceNoteBubble(voiceNote: vn, itemID: item.id, isOutgoing: item.isOutgoing)
            } else if item.mediaData != nil || item.mediaTransferID != nil {
                MediaImageBubble(item: item, isOutgoing: item.isOutgoing)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.text)
                        .font(.body)
                        .foregroundStyle(item.isOutgoing ? Color.white : MeshTheme.primaryText)

                    if let coord = item.coordinate {
                        GeoLocationLinkChip(coordinate: coord, label: "Tọa độ từ \(item.senderName)")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    item.isOutgoing ? MeshTheme.emerald : MeshTheme.cardSurface,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .frame(maxWidth: 320, alignment: item.isOutgoing ? .trailing : .leading)
            }

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

    private func sosBroadcastCard(_ item: ChatThreadItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "light.beacon.max.fill")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(MeshTheme.sosCrimson)

                Text("KHẨN CẤP SOS TỪ \(item.senderName)")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(MeshTheme.sosCrimson)

                Spacer()

                Text(item.timestamp, format: .dateTime.hour().minute())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MeshTheme.secondaryText)
            }

            Text(item.text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white)

            if let coord = item.coordinate {
                GeoLocationLinkChip(coordinate: coord, label: "Tọa độ cầu cứu")
            }

            HopPathBadge(
                routeNames: item.routeNames,
                hopCount: item.hopCount,
                deliveryState: item.deliveryState,
                rttMs: item.rttMs
            )
        }
        .padding(14)
        .background(MeshTheme.sosCrimson.opacity(0.15), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(MeshTheme.sosCrimson.opacity(0.4), lineWidth: 1)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard let lastID = coordinator.broadcastMessages.last?.id else { return }
        if animated {
            withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

// MARK: - 2. DTN Outbox View (Chờ DTN)

private struct DTNOutboxView: View {
    var coordinator: MeshCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Header with flush control
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hàng đợi Lưu và Chuyển tiếp (DTN)")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(MeshTheme.primaryText)

                        Text("Các gói tin E2EE đang lưu trên ổ đĩa chờ trạm trung gian mang đi.")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.secondaryText)
                    }

                    Spacer()

                    if !coordinator.dtnRecords.isEmpty {
                        Button {
                            withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                                coordinator.flushDTNOutbox()
                            }
                        } label: {
                            Text("Thử xả gửi")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(MeshTheme.dtnIndigo, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)

                if coordinator.dtnRecords.isEmpty {
                    emptyDTNState
                        .padding(.top, 24)
                        .padding(.horizontal, 16)
                } else {
                    VStack(spacing: 10) {
                        ForEach(coordinator.dtnRecords) { record in
                            dtnRecordCard(record)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 96)
        }
    }

    private func dtnRecordCard(_ record: StoredDTNRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(MeshTheme.dtnIndigo)

                Text("Tới: \(record.packet.targetID)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(MeshTheme.primaryText)

                Spacer()

                Text("TTL: \(record.packet.ttl)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(MeshTheme.secondaryText)
            }

            Text("Gói tin \(record.packet.type.rawValue.uppercased()) · ID: \(record.id.uuidString.prefix(8))…")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(MeshTheme.secondaryText)
                .lineLimit(2)

            HStack {
                Text("Lưu lúc: \(record.queuedAt, format: .dateTime.hour().minute().second())")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MeshTheme.secondaryText)

                Spacer()

                Text("Hết hạn: \(record.expiresAt, format: .dateTime.hour().minute())")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MeshTheme.secondaryText)
            }
        }
        .padding(14)
        .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var emptyDTNState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(MeshTheme.dtnIndigo)

            Text("Hộp thư chờ DTN đang trống")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(MeshTheme.primaryText)

            Text("Khi bạn nhắn tin cho một trạm đang mất sóng, gói tin sẽ được mã hóa và cất vào đây để gửi tự động khi gặp lại.")
                .font(.caption)
                .foregroundStyle(MeshTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - 3. 1-to-1 Chat Room View

public struct DirectPeerChatRoomView: View {
    public var coordinator: MeshCoordinator
    public let peerID: String
    public var navigationPath: Binding<[MessagesTab.ChatDestination]>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingFingerprintSheet = false
    @State private var isShowingCompassSheet = false
    @State private var isShowingQRSheet = false
    @State private var sendFeedbackCount = 0

    private var peer: PeerSummary {
        coordinator.peerSummary(for: peerID)
    }

    private var messages: [ChatThreadItem] {
        coordinator.messages(forPeerID: peerID)
    }

    public init(coordinator: MeshCoordinator, peerID: String, navigationPath: Binding<[MessagesTab.ChatDestination]>? = nil) {
        self.coordinator = coordinator
        self.peerID = peerID
        self.navigationPath = navigationPath
    }

    private var routeSummaryText: String {
        switch peer.linkKind {
        case .directP2P:
            return "1-Hop P2P"
        case let .relayedMesh(_, viaName, hops):
            return "\(hops)-Hop qua \(viaName)"
        case .offlineDTN:
            return "Ngoại tuyến DTN"
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // MITM Key Conflict Alert Banner
            if peer.trustState == .keyConflict {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(MeshTheme.sosCrimson)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CẢNH BÁO: KHÓA THAY ĐỔI (MITM)")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(MeshTheme.sosCrimson)
                        Text("Khóa công khai của \(peer.identity.displayName) không khớp với lần đầu kết nối.")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(MeshTheme.primaryText)
                    }
                    Spacer()
                    Button("Đối chiếu QR") {
                        isShowingQRSheet = true
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(MeshTheme.sosCrimson, in: Capsule())
                }
                .padding(10)
                .background(MeshTheme.sosCrimson.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }

            // Message Stream
            ScrollViewReader { proxy in
                ScrollView {
                    if messages.isEmpty {
                        emptyRoomState
                            .padding(.top, 40)
                            .padding(.horizontal, 20)
                    } else {
                        LazyVStack(spacing: 14) {
                            ForEach(messages) { item in
                                directBubbleRow(item)
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 12)
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

            // Smart Composer Bar
            SmartComposerBar(
                isBroadcast: false,
                recipientName: peer.identity.displayName,
                onSendText: { text, gps in
                    sendFeedbackCount += 1
                    coordinator.sendDirectMessage(to: peerID, text: text, includeLocation: gps)
                },
                onSendVoice: { vn in
                    sendFeedbackCount += 1
                    coordinator.sendVoiceNote(voiceNote: vn, to: peerID)
                },
                onSendMedia: { data, caption in
                    sendFeedbackCount += 1
                    coordinator.sendMedia(data: data, caption: caption, to: peerID)
                },
                onTriggerRollCall: nil,
                onTriggerPoll: nil
            )
        }
        .background(MeshTheme.background)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(peer.identity.displayName)
                            .font(.headline)
                            .foregroundStyle(MeshTheme.primaryText)
                        Text("\(routeSummaryText) • E2EE")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.secondaryText)
                    }
                    PeerTrustBadge(trustState: peer.trustState, compact: true)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) {
                    Button {
                        coordinator.startHeadingUpdates()
                        isShowingCompassSheet = true
                    } label: {
                        Image(systemName: "location.north.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(MeshTheme.emerald)
                    }
                    .buttonStyle(.plain)

                    Button {
                        isShowingQRSheet = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 18))
                            .foregroundStyle(MeshTheme.meshCyan)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear {
            coordinator.isChatActive = true
            coordinator.selectedDirectPeerID = peerID
        }
        .onDisappear {
            if navigationPath?.wrappedValue.isEmpty ?? true {
                coordinator.isChatActive = false
                coordinator.selectedDirectPeerID = nil
            }
        }
        .sheet(isPresented: $isShowingFingerprintSheet) {
            KeyFingerprintSheet(local: coordinator.localIdentity, peer: peer.identity)
        }
        .sheet(isPresented: $isShowingCompassSheet) {
            PeerCompassSheet(
                localCoordinate: coordinator.latestLocalCoordinate,
                peer: peer,
                deviceHeading: coordinator.deviceHeading,
                onHeadingSliderChanged: { coordinator.updateSimulatedHeading(degrees: $0) }
            )
        }
        .sheet(isPresented: $isShowingQRSheet) {
            QRTrustSheet(
                localNode: coordinator.localIdentity,
                targetPeer: peer,
                onVerifyPeer: { pid, fp in
                    coordinator.verifyPeerOutOfBand(peerID: pid, fingerprint: fp)
                },
                onTrustConflictingKey: { pid in
                    coordinator.trustConflictingKey(peerID: pid)
                },
                onSimulateKeyConflict: { pid in
                    coordinator.mockSimulateKeyConflict(peerID: pid)
                }
            )
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sendFeedbackCount)
    }

    private func directBubbleRow(_ item: ChatThreadItem) -> some View {
        VStack(alignment: item.isOutgoing ? .trailing : .leading, spacing: 4) {
            Text(item.timestamp, format: .dateTime.hour().minute())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(MeshTheme.secondaryText)
                .padding(.horizontal, 4)

            // Dynamic Bubble (Voice / Media Image / Text)
            if let vn = item.voiceNote {
                VoiceNoteBubble(voiceNote: vn, itemID: item.id, isOutgoing: item.isOutgoing)
            } else if item.mediaData != nil || item.mediaTransferID != nil {
                MediaImageBubble(item: item, isOutgoing: item.isOutgoing)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.text)
                        .font(.body)
                        .foregroundStyle(item.isOutgoing ? Color.white : MeshTheme.primaryText)

                    if let coord = item.coordinate {
                        GeoLocationLinkChip(coordinate: coord, label: "Tọa độ từ \(item.senderName)")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    item.isOutgoing ? MeshTheme.emerald : MeshTheme.cardSurface,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .frame(maxWidth: 320, alignment: item.isOutgoing ? .trailing : .leading)
            }

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

    private var emptyRoomState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(MeshTheme.emerald)

            Text("Trò chuyện Mã hóa Đầu-Cuối (E2EE)")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(MeshTheme.primaryText)

            Text("Chỉ bạn và \(peer.identity.displayName) có khóa để giải mã tin nhắn. Các máy trung chuyển hoàn toàn mù nội dung.")
                .font(.caption)
                .foregroundStyle(MeshTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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

// MARK: - 4. Key Fingerprint Verification Sheet

private struct KeyFingerprintSheet: View {
    let local: NodeIdentity
    let peer: NodeIdentity

    @Environment(\.dismiss) private var dismiss
    @State private var copiedFingerprint = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Shield header
                    VStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(MeshTheme.emerald)

                        Text("Xác thực Khóa Mã hóa")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(MeshTheme.primaryText)

                        Text("So sánh dấu vân tay khóa công khai với đối tác ngoài đời thực để đảm bảo không bị tấn công kẻ trung gian (MITM).")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    .padding(.top, 16)

                    // Fingerprint Card
                    VStack(alignment: .leading, spacing: 14) {
                        fingerprintRow(
                            title: "KHÓA CỦA BẠN (\(local.displayName))",
                            nodeID: local.nodeID,
                            publicKey: local.publicKeyBase64
                        )

                        Divider()
                            .overlay(MeshTheme.hairlineBorder)

                        fingerprintRow(
                            title: "KHÓA ĐỐI TÁC (\(peer.displayName))",
                            nodeID: peer.nodeID,
                            publicKey: peer.publicKeyBase64
                        )
                    }
                    .padding(16)
                    .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, 16)

                    // Copy Action
                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = peer.publicKeyBase64
                        #endif
                        copiedFingerprint = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: copiedFingerprint ? "checkmark.circle.fill" : "doc.on.doc.fill")
                            Text(copiedFingerprint ? "Đã sao chép khóa đối tác" : "Sao chép khóa công khai của \(peer.displayName)")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(copiedFingerprint ? MeshTheme.emerald : Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            copiedFingerprint ? MeshTheme.emerald.opacity(0.18) : MeshTheme.cardSurface,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 24)
            }
            .background(MeshTheme.background)
            .navigationTitle("Khóa E2EE")
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
    }

    private func fingerprintRow(title: String, nodeID: String, publicKey: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(MeshTheme.secondaryText)

            Text("Node ID: \(nodeID)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(MeshTheme.emerald)

            let keyText = publicKey?.isEmpty == false ? publicKey! : "Chưa có khóa (Mô phỏng)"
            Text(keyText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(MeshTheme.primaryText)
                .lineLimit(3)
        }
    }
}
#endif
