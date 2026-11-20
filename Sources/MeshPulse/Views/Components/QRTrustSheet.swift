#if canImport(SwiftUI)
import CoreImage.CIFilterBuiltins
import Foundation
import MeshCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Out-of-band QR Verification sheet:
/// Displays local node's QR code + fingerprint, and verifies peers via camera scan or simulation.
public struct QRTrustSheet: View {
    @Environment(\.dismiss) private var dismiss
    public let localNode: NodeIdentity
    public let targetPeer: PeerSummary?
    public let onVerifyPeer: ((String, String) -> Void)?
    public let onTrustConflictingKey: ((String) -> Void)?
    public let onSimulateKeyConflict: ((String) -> Void)?

    @State private var selectedTab: Int = 0
    @State private var statusFeedback: String?
    @State private var generatedImage: Image?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        localNode: NodeIdentity,
        targetPeer: PeerSummary? = nil,
        onVerifyPeer: ((String, String) -> Void)? = nil,
        onTrustConflictingKey: ((String) -> Void)? = nil,
        onSimulateKeyConflict: ((String) -> Void)? = nil
    ) {
        self.localNode = localNode
        self.targetPeer = targetPeer
        self.onVerifyPeer = onVerifyPeer
        self.onTrustConflictingKey = onTrustConflictingKey
        self.onSimulateKeyConflict = onSimulateKeyConflict
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker("Chế độ", selection: $selectedTab) {
                        Text("Mã QR Của Bạn").tag(0)
                        Text(targetPeer != nil ? "Xác Thực Đối Tác" : "Quét Mã Đối Tác").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    if selectedTab == 0 {
                        myQRCodeView
                    } else {
                        verifyPeerSection
                    }
                }
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(MeshTheme.background)
            .navigationTitle("Xác Thực An Toàn (TOFU)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(MeshTheme.emerald)
                }
            }
        }
        .presentationDetents([.fraction(0.78), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(MeshTheme.background)
        .onAppear {
            generateQRCodeImage()
            if targetPeer != nil {
                selectedTab = 1
            }
        }
    }

    // MARK: - Tab 1: Local Node QR

    private var myQRCodeView: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text(localNode.displayName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(MeshTheme.primaryText)
                Text("ID: \(localNode.nodeID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(MeshTheme.secondaryText)
            }
            .padding(.top, 4)

            // QR Code Container
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 224, height: 224)
                    .shadow(color: MeshTheme.emerald.opacity(0.18), radius: 16, y: 4)

                if let img = generatedImage {
                    img
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                } else {
                    ProgressView()
                        .tint(MeshTheme.emeraldDark)
                }
            }

            VStack(spacing: 8) {
                Text("VÂN TAY KHÓA CÔNG KHAI")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(MeshTheme.secondaryText)
                Text(localNode.publicKeyFingerprint ?? "N/A")
                    .font(.system(.body, design: .monospaced, weight: .bold))
                    .foregroundStyle(MeshTheme.emeraldLight)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(MeshTheme.emerald.opacity(0.14), in: Capsule())
            }

            Text("Để đối tác quét mã này bằng camera để xác thực khóa tận tay (Out-of-Band), bảo vệ vĩnh viễn khỏi tấn công nghe lén giả mạo.")
                .font(.footnote)
                .foregroundStyle(MeshTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Tab 2: Verify Peer

    private var verifyPeerSection: some View {
        VStack(spacing: 16) {
            if let peer = targetPeer {
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(MeshTheme.emerald.opacity(0.14))
                                .frame(width: 42, height: 42)
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(MeshTheme.emerald)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(peer.identity.displayName)
                                .font(.headline)
                                .foregroundStyle(MeshTheme.primaryText)
                                .lineLimit(1)
                            Text("ID: \(peer.identity.nodeID)")
                                .font(.caption.monospaced())
                                .foregroundStyle(MeshTheme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        PeerTrustBadge(trustState: peer.trustState, compact: true)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(14)
                    .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if peer.trustState == .keyConflict {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(MeshTheme.sosCrimson)
                                Text("CẢNH BÁO XUNG ĐỘT KHÓA (MITM)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(MeshTheme.sosCrimson)
                            }
                            Text("Khóa công khai nhận được từ sóng radio khác với khóa đã ghim ban đầu. Đây có thể là tấn công giả mạo hoặc trạm đã cài đặt lại máy.")
                                .font(.caption)
                                .foregroundStyle(MeshTheme.primaryText.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)

                            Button {
                                onTrustConflictingKey?(peer.identity.nodeID)
                                withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                                    statusFeedback = "✓ Đã chấp nhận và ghim khóa công khai mới."
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.shield")
                                    Text("Tôi tin tưởng & Ghim Khóa Mới")
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: MeshTheme.minTapDimension)
                                .background(MeshTheme.meshAmber, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.applePressable)
                        }
                        .padding(14)
                        .background(MeshTheme.sosCrimson.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(MeshTheme.sosCrimson.opacity(0.35), lineWidth: 1)
                        )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("VÂN TAY ĐỐI CHIẾU")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(MeshTheme.secondaryText)
                        Text(peer.identity.publicKeyFingerprint ?? "Không có khóa")
                            .font(.subheadline.monospaced().weight(.semibold))
                            .foregroundStyle(MeshTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    // Action buttons
                    VStack(spacing: 10) {
                        Button {
                            if let fp = peer.identity.publicKeyFingerprint {
                                onVerifyPeer?(peer.identity.nodeID, fp)
                                withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                                    statusFeedback = "🛡️ Đã xác thực trạm thành công!"
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.shield.fill")
                                Text("Xác Thực Vân Tay Khớp (Quét QR)")
                            }
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(MeshTheme.emeraldDark, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.applePressable)

                        // Simulation / testing buttons
                        HStack(spacing: 10) {
                            Button {
                                onSimulateKeyConflict?(peer.identity.nodeID)
                                withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                                    statusFeedback = "⚠️ Đã kích hoạt xung đột khóa giả lập."
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "exclamationmark.triangle")
                                    Text("Giả lập MITM")
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(MeshTheme.meshAmber)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: MeshTheme.minTapDimension)
                                .background(MeshTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.applePressable)

                            Button {
                                if let fp = peer.identity.publicKeyFingerprint {
                                    onVerifyPeer?(peer.identity.nodeID, fp)
                                    withAnimation(MeshTheme.animation(reduceMotion: reduceMotion)) {
                                        statusFeedback = "🛡️ Đã chuyển sang Trạng thái Xác thực."
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "qrcode.viewfinder")
                                    Text("Mô phỏng Quét")
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(MeshTheme.emeraldLight)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: MeshTheme.minTapDimension)
                                .background(MeshTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.applePressable)
                        }
                    }
                }
                .padding(.horizontal, 20)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(MeshTheme.emerald.opacity(0.8))
                    Text("Chọn một trạm từ danh sách Trạm Mạng để xác thực khóa công khai.")
                        .font(.subheadline)
                        .foregroundStyle(MeshTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 32)
                .padding(.top, 36)
            }

            if let fb = statusFeedback {
                Text(fb)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MeshTheme.emeraldLight)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(MeshTheme.emerald.opacity(0.12), in: Capsule())
                    .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Helpers

    private func generateQRCodeImage() {
        let uri = localNode.verificationURIString
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(uri.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return }

        #if canImport(UIKit)
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        if let cgImage = context.createCGImage(transformed, from: transformed.extent) {
            self.generatedImage = Image(uiImage: UIImage(cgImage: cgImage))
        }
        #endif
    }
}
#endif
