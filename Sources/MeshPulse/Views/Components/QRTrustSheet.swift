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
    @State private var inputURI: String = ""
    @State private var statusFeedback: String?
    @State private var generatedImage: Image?

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
            ZStack {
                MeshTheme.background
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    Picker("Chế độ", selection: $selectedTab) {
                        Text("Mã QR Của Bạn").tag(0)
                        Text(targetPeer != nil ? "Xác Thực Đối Tác" : "Quét Mã Đối Tác").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                    if selectedTab == 0 {
                        myQRCodeView
                    } else {
                        verifyPeerSection
                    }

                    Spacer()
                }
            }
            .navigationTitle("Xác Thực An Toàn (TOFU)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Xong") {
                        dismiss()
                    }
                    .foregroundStyle(MeshTheme.emerald)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
            VStack(spacing: 8) {
                Text(localNode.displayName)
                    .font(.headline)
                    .foregroundStyle(MeshTheme.primaryText)
                Text("ID: \(localNode.nodeID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(MeshTheme.secondaryText)
            }
            .padding(.top, 8)

            // QR Code Container
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white)
                    .frame(width: 220, height: 220)
                    .shadow(color: MeshTheme.emerald.opacity(0.15), radius: 16)

                if let img = generatedImage {
                    img
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                } else {
                    ProgressView()
                }
            }

            VStack(spacing: 6) {
                Text("VÂN TAY KHÓA CÔNG KHAI")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(MeshTheme.secondaryText)
                Text(localNode.publicKeyFingerprint ?? "N/A")
                    .font(.system(.body, design: .monospaced, weight: .bold))
                    .foregroundStyle(MeshTheme.emerald)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(MeshTheme.emerald.opacity(0.12), in: Capsule())
            }

            Text("Để đối tác quét mã này bằng camera để xác thực khóa tận tay (Out-of-Band), bảo vệ vĩnh viễn khỏi tấn công nghe lén giả mạo.")
                .font(.footnote)
                .foregroundStyle(MeshTheme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
    }

    // MARK: - Tab 2: Verify Peer

    private var verifyPeerSection: some View {
        VStack(spacing: 18) {
            if let peer = targetPeer {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.title2)
                            .foregroundStyle(MeshTheme.emerald)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(peer.displayName)
                                .font(.headline)
                                .foregroundStyle(MeshTheme.primaryText)
                            Text("ID: \(peer.nodeID)")
                                .font(.caption.monospaced())
                                .foregroundStyle(MeshTheme.secondaryText)
                        }
                        Spacer()
                        PeerTrustBadge(trustState: peer.trustState)
                    }
                    .padding(14)
                    .background(MeshTheme.cardBackground, in: RoundedRectangle(cornerRadius: 14))

                    if peer.trustState == .keyConflict {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(MeshTheme.sosCrimson)
                                Text("CẢNH BÁO XUNG ĐỘT KHÓA (MITM)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(MeshTheme.sosCrimson)
                            }
                            Text("Khóa công khai nhận được từ sóng radio khác với khóa đã ghim ban đầu. Đây có thể là tấn công giả mạo hoặc trạm đã cài đặt lại máy.")
                                .font(.caption)
                                .foregroundStyle(MeshTheme.secondaryText)

                            Button(action: {
                                onTrustConflictingKey?(peer.nodeID)
                                statusFeedback = "✓ Đã chấp nhận và ghim khóa công khai mới."
                            }) {
                                HStack {
                                    Image(systemName: "checkmark.shield")
                                    Text("Tôi tin tưởng & Ghim Khóa Mới")
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(MeshTheme.meshAmber, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(14)
                        .background(MeshTheme.sosCrimson.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(MeshTheme.sosCrimson.opacity(0.35), lineWidth: 1))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Vân tay đối chiếu:")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(MeshTheme.secondaryText)
                        Text(peer.publicKeyFingerprint ?? "Không có khóa")
                            .font(.caption.monospaced())
                            .foregroundStyle(MeshTheme.primaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                    // Action buttons
                    VStack(spacing: 10) {
                        Button(action: {
                            if let fp = peer.publicKeyFingerprint {
                                onVerifyPeer?(peer.nodeID, fp)
                                statusFeedback = "🛡️ Đã xác thực trạm thành công!"
                            }
                        }) {
                            HStack {
                                Image(systemName: "checkmark.shield.fill")
                                Text("Xác Thực Vân Tay Khớp (Quét QR)")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(MeshTheme.emerald, in: RoundedRectangle(cornerRadius: 10))
                        }

                        // Simulation / testing buttons
                        HStack(spacing: 10) {
                            Button(action: {
                                onSimulateKeyConflict?(peer.nodeID)
                                statusFeedback = "⚠️ Đã kích hoạt xung đột khóa giả lập."
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle")
                                    Text("Giả lập MITM")
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(MeshTheme.meshAmber)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(MeshTheme.meshAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            }

                            Button(action: {
                                if let fp = peer.publicKeyFingerprint {
                                    onVerifyPeer?(peer.nodeID, fp)
                                    statusFeedback = "🛡️ Đã chuyển sang Trạng thái Xác thực."
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "qrcode.viewfinder")
                                    Text("Mô phỏng Quét")
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(MeshTheme.emerald)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(MeshTheme.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            } else {
                Text("Chọn một trạm từ danh sách Trạm Mạng để xác thực khóa công khai.")
                    .font(.subheadline)
                    .foregroundStyle(MeshTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 40)
            }

            if let fb = statusFeedback {
                Text(fb)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MeshTheme.emerald)
                    .padding(.top, 6)
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
