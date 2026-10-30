#if canImport(SwiftUI)
import MeshCore
import SwiftUI

/// Tab 2 (`Kênh Chung`): Network-wide multi-hop Broadcast & SOS emergency feed
/// with per-message `HopPathBadge` and offline GPS Apple Maps attachments.
public struct BroadcastChatTab: View {
    public var coordinator: MeshCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draftText = ""
    @State private var includeGPS = false
    @State private var sendFeedbackCount = 0

    public init(coordinator: MeshCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(spacing: 0) {
            channelBanner

            ScrollViewReader { proxy in
                ScrollView {
                    if coordinator.broadcastMessages.isEmpty {
                        emptyBroadcastState
                            .padding(.top, 48)
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
                        .padding(.vertical, 14)
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

            composerBar
        }
        .background(MeshTheme.background)
        .sensoryFeedback(.impact(weight: .light), trigger: sendFeedbackCount)
    }

    // MARK: - Subheader & Empty State

    private var channelBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MeshTheme.meshAmber)

            Text("Phát quảng bá đa bước nhảy (ALL) · Không mã hóa E2EE")
                .font(.caption)
                .foregroundStyle(MeshTheme.secondaryText)
                .lineLimit(1)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(MeshTheme.cardSurface.opacity(0.75))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MeshTheme.hairlineBorder)
                .frame(height: 1)
        }
    }

    private var emptyBroadcastState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                .font(.title2.weight(.semibold))
                .foregroundStyle(MeshTheme.secondaryText)

            Text("Chưa có bản tin Kênh Chung")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MeshTheme.primaryText)

            Text("Tin nhắn gửi tại đây được quảng bá tới mọi trạm trong tầm bước nhảy TTL và kèm nhãn lộ trình thực tế.")
                .font(.caption)
                .foregroundStyle(MeshTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .meshCard()
    }

    // MARK: - Message Bubbles & SOS Card

    private func broadcastMessageRow(_ item: ChatThreadItem) -> some View {
        VStack(alignment: item.isOutgoing ? .trailing : .leading, spacing: 6) {
            HStack(spacing: 6) {
                if !item.isOutgoing {
                    Text(item.senderName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MeshTheme.primaryText)
                }
                Text(item.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MeshTheme.secondaryText)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(item.text)
                    .font(.body)
                    .foregroundStyle(MeshTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let coord = item.coordinate {
                    GeoLocationLinkChip(
                        coordinate: coord,
                        label: item.senderName,
                        tint: MeshTheme.p2pGreen
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                item.isOutgoing ? MeshTheme.p2pGreen.opacity(0.18) : MeshTheme.cardSurface,
                in: RoundedRectangle(cornerRadius: MeshTheme.cardCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: MeshTheme.cardCornerRadius, style: .continuous)
                    .strokeBorder(
                        item.isOutgoing ? MeshTheme.p2pGreen.opacity(0.38) : MeshTheme.hairlineBorder,
                        lineWidth: 1
                    )
            }
            .frame(maxWidth: 320, alignment: item.isOutgoing ? .trailing : .leading)

            HopPathBadge(
                routeNames: item.routeNames,
                hopCount: item.hopCount,
                deliveryState: item.isOutgoing ? item.deliveryState : nil,
                rttMs: item.rttMs
            )
        }
        .frame(maxWidth: .infinity, alignment: item.isOutgoing ? .trailing : .leading)
    }

    private func sosBroadcastCard(_ item: ChatThreadItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "light.beacon.max.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(MeshTheme.sosCrimson)

                Text("TÍN HIỆU KHẨN CẤP SOS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(MeshTheme.sosCrimson)

                Spacer(minLength: 4)

                Text(item.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MeshTheme.secondaryText)
            }

            Text("\(item.senderName) (\(item.senderID))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MeshTheme.primaryText)

            Text(item.text)
                .font(.body)
                .foregroundStyle(MeshTheme.primaryText)

            if let coord = item.coordinate {
                GeoLocationLinkChip(
                    coordinate: coord,
                    label: "SOS - \(item.senderName)",
                    tint: MeshTheme.sosCrimson
                )
            }

            HStack {
                HopPathBadge(
                    routeNames: item.routeNames,
                    hopCount: item.hopCount,
                    deliveryState: item.isOutgoing ? item.deliveryState : nil,
                    rttMs: item.rttMs
                )
                Spacer()
                Text("TTL còn \(item.remainingTTL)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MeshTheme.secondaryText)
            }
        }
        .padding(14)
        .background(
            MeshTheme.sosCrimson.opacity(0.14),
            in: RoundedRectangle(cornerRadius: MeshTheme.cardCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: MeshTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(MeshTheme.sosCrimson.opacity(0.55), lineWidth: 1)
        }
    }

    // MARK: - Composer Bar

    private var composerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if includeGPS {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                        .font(.caption2.weight(.bold))
                    Text("Sẽ đính kèm tọa độ GPS ngoại tuyến vào tin nhắn này")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(MeshTheme.p2pGreen)
                .padding(.horizontal, 4)
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
                                lineWidth: 1
                            )
                        }
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: includeGPS)
                .accessibilityLabel(includeGPS ? "Đã bật đính kèm vị trí GPS" : "Đính kèm vị trí GPS")

                TextField("Gửi tin nhắn toàn mạng...", text: $draftText, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.body)
                    .foregroundStyle(MeshTheme.primaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: MeshTheme.minTapDimension)
                    .background(MeshTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(MeshTheme.hairlineBorder, lineWidth: 1)
                    }

                Button {
                    submitBroadcast()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(canSend ? MeshTheme.background : MeshTheme.secondaryText)
                        .frame(width: MeshTheme.minTapDimension, height: MeshTheme.minTapDimension)
                        .background(canSend ? MeshTheme.p2pGreen : MeshTheme.elevatedSurface, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Gửi tin nhắn quảng bá")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(MeshTheme.cardSurface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MeshTheme.hairlineBorder)
                .frame(height: 1)
        }
    }

    private var canSend: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || includeGPS
    }

    private func submitBroadcast() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalBody = trimmed.isEmpty && includeGPS ? "Chia sẻ tọa độ GPS ngoại tuyến." : trimmed
        guard !finalBody.isEmpty else { return }

        sendFeedbackCount += 1
        coordinator.sendBroadcast(text: finalBody, includeLocation: includeGPS)
        draftText = ""
        includeGPS = false
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
#endif
