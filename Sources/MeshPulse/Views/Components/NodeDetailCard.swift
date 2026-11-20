#if canImport(SwiftUI)
import MeshCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Detailed Station Inspection Card modeled after Apple Contacts / Find My:
/// - Visual Summary Row: 56x56pt soft-tinted circular avatar + custom circular signal ring
/// - Full-width horizontally scrollable status/trust badges row
/// - Clean Inset Grouped Property Rows: Route path and Public Key with one-tap Copy
/// - Direct Action Section: Full-width Primary CTA + 4 uniform Quick Action tiles
public struct NodeDetailCard: View {
    public let peer: PeerSummary
    public var coordinator: MeshCoordinator

    @State private var hasCopiedKey = false
    @State private var pingFeedbackCount = 0
    @State private var showingCompassSheet = false
    @State private var showingQRSheet = false

    public init(peer: PeerSummary, coordinator: MeshCoordinator) {
        self.peer = peer
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: 1. Header Row (56x56 Avatar, Name/ID, Custom 56x56 Signal Ring)
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(MeshTheme.emerald.opacity(0.16))
                        .frame(width: 56, height: 56)

                    Text(stationMonogram)
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .foregroundStyle(MeshTheme.emerald)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(peer.identity.displayName)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(MeshTheme.primaryText)
                        .lineLimit(1)

                    Text("ID: \(peer.identity.nodeID)")
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(MeshTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                signalRingView
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Full-width horizontally scrollable badge row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    LinkStatusBadge(linkKind: peer.linkKind)
                        .fixedSize(horizontal: true, vertical: false)

                    PeerTrustBadge(trustState: peer.trustState, compact: true)
                        .fixedSize(horizontal: true, vertical: false)

                    if isBlocked {
                        Text("Đã chặn")
                            .font(.system(size: 10, weight: .bold))
                            .lineLimit(1)
                            .foregroundStyle(MeshTheme.sosCrimson)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(MeshTheme.sosCrimson.opacity(0.16), in: Capsule())
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 14)

            if peer.trustState == .keyConflict {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(MeshTheme.sosCrimson)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CẢNH BÁO: KHÓA CÔNG KHAI THAY ĐỔI")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(MeshTheme.sosCrimson)
                        Text("Nghi vấn trạm bị tấn công giả mạo (MITM). Hãy quét QR xác thực.")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(MeshTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Xác thực") {
                        showingQRSheet = true
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(MeshTheme.sosCrimson, in: Capsule())
                    .contentShape(Capsule())
                    .buttonStyle(.applePressable)
                }
                .padding(10)
                .background(MeshTheme.sosCrimson.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            Divider()
                .overlay(MeshTheme.hairlineBorder)
                .padding(.leading, 16)

            // MARK: 2. Clean Flat Property Rows
            VStack(spacing: 0) {
                propertyRow(
                    icon: "arrow.triangle.branch",
                    title: "Lộ trình",
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

            // MARK: 3. Direct Apple Contacts-Style Action Section
            actionSection
                .padding(16)
        }
        .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .sensoryFeedback(.impact(weight: .light), trigger: pingFeedbackCount)
        .sensoryFeedback(.success, trigger: hasCopiedKey)
        .sheet(isPresented: $showingCompassSheet) {
            PeerCompassSheet(
                localCoordinate: coordinator.latestLocalCoordinate,
                peer: peer,
                deviceHeading: coordinator.deviceHeading,
                onHeadingSliderChanged: { coordinator.updateSimulatedHeading(degrees: $0) }
            )
        }
        .sheet(isPresented: $showingQRSheet) {
            QRTrustSheet(
                localNode: coordinator.localIdentity,
                targetPeer: peer,
                onVerifyPeer: { peerID, fp in
                    coordinator.verifyPeerOutOfBand(peerID: peerID, fingerprint: fp)
                },
                onTrustConflictingKey: { peerID in
                    coordinator.trustConflictingKey(peerID: peerID)
                },
                onSimulateKeyConflict: { peerID in
                    coordinator.mockSimulateKeyConflict(peerID: peerID)
                }
            )
        }
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

    private var signalColor: Color {
        if peer.linkKind == .offlineDTN {
            return MeshTheme.dtnIndigo
        }
        if signalQualityPercent >= 80 {
            return MeshTheme.emerald
        }
        if signalQualityPercent >= 50 {
            return MeshTheme.meshAmber
        }
        return MeshTheme.sosCrimson
    }

    private var signalRingView: some View {
        ZStack {
            Circle()
                .stroke(signalColor.opacity(0.18), lineWidth: 5)

            Circle()
                .trim(from: 0, to: min(max(signalQualityPercent / 100.0, 0), 1))
                .stroke(signalColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 0) {
                Text("\(Int(signalQualityPercent))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(MeshTheme.primaryText)
                Text(latencyLabel)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(MeshTheme.secondaryText)
            }
        }
        .frame(width: 56, height: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tín hiệu \(Int(signalQualityPercent)) phần trăm, \(latencyLabel)")
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

            Spacer(minLength: 12)

            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MeshTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
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

            Text("Khóa công khai")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(MeshTheme.secondaryText)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Text(peer.identity.publicKeyFingerprint ?? "E2EE-Active")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(MeshTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

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
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(MeshTheme.emerald.opacity(0.14), in: Capsule())
                    .contentShape(Rectangle())
                }
                .buttonStyle(.applePressable)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var actionSection: some View {
        VStack(spacing: 10) {
            // Primary CTA: Encrypted Chat
            Button {
                withAnimation(MeshTheme.fluidSpring) {
                    coordinator.openDirectConversation(with: peer.id)
                }
            } label: {
                Label("Nhắn tin mã hóa", systemImage: "bubble.left.and.lock.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(MeshTheme.emeraldDark, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.applePressable)

            // Secondary Quick Actions Grid (Apple Contacts style)
            HStack(spacing: 8) {
                quickActionTile(
                    title: "Ping",
                    systemImage: "waveform.path.ecg",
                    iconColor: MeshTheme.emerald,
                    isDisabled: peer.linkKind == .offlineDTN
                ) {
                    pingFeedbackCount += 1
                    coordinator.ping(peerID: peer.id)
                }

                quickActionTile(
                    title: "Dò vị trí",
                    systemImage: "location.north.circle.fill",
                    iconColor: MeshTheme.emerald
                ) {
                    coordinator.startHeadingUpdates()
                    showingCompassSheet = true
                }

                quickActionTile(
                    title: "Mã QR",
                    systemImage: "qrcode.viewfinder",
                    iconColor: MeshTheme.emerald
                ) {
                    showingQRSheet = true
                }

                quickActionTile(
                    title: isBlocked ? "Bỏ chặn" : "Chặn",
                    systemImage: isBlocked ? "checkmark.circle" : "slash.circle",
                    iconColor: isBlocked ? MeshTheme.emerald : MeshTheme.sosCrimson
                ) {
                    withAnimation(MeshTheme.fluidSpring) {
                        coordinator.toggleTopologyBlock(for: peer.id)
                    }
                }
            }
        }
    }

    private func quickActionTile(
        title: String,
        systemImage: String,
        iconColor: Color,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(iconColor)

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MeshTheme.primaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(MeshTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.applePressable)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1.0)
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
