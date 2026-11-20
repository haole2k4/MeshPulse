#if canImport(SwiftUI)
import Foundation
import MeshCore
import SwiftUI

/// AirTag-style Precision Finding compass sheet:
/// Calculates distance via Haversine, bearing via Azimuth, and renders a smooth rotating arrow
/// locked to real-time CLHeading with emerald lock-on feedback within ±15°.
public struct PeerCompassSheet: View {
    @Environment(\.dismiss) private var dismiss
    public let localCoordinate: GeoCoordinate?
    public let peer: PeerSummary
    public let deviceHeading: Double
    public let onHeadingSliderChanged: ((Double) -> Void)?

    @State private var simulatedHeading: Double = 0.0
    @State private var useSimulationSlider: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        localCoordinate: GeoCoordinate?,
        peer: PeerSummary,
        deviceHeading: Double,
        onHeadingSliderChanged: ((Double) -> Void)? = nil
    ) {
        self.localCoordinate = localCoordinate
        self.peer = peer
        self.deviceHeading = deviceHeading
        self.onHeadingSliderChanged = onHeadingSliderChanged
    }

    private var effectiveHeading: Double {
        useSimulationSlider ? simulatedHeading : deviceHeading
    }

    private var peerCoord: GeoCoordinate? {
        peer.lastCoordinate
    }

    private var distanceMeters: Double? {
        guard let local = localCoordinate, let target = peerCoord else { return nil }
        return ProximityMath.haversineDistanceMeters(from: local, to: target)
    }

    private var targetBearing: Double? {
        guard let local = localCoordinate, let target = peerCoord else { return nil }
        return ProximityMath.bearingDegrees(from: local, to: target)
    }

    private var relativeArrowAngle: Double {
        guard let bearing = targetBearing else { return 0.0 }
        return ProximityMath.relativeArrowAngleDegrees(bearing: bearing, deviceHeading: effectiveHeading)
    }

    private var isLockedOn: Bool {
        guard targetBearing != nil else { return false }
        let diff = abs(relativeArrowAngle.truncatingRemainder(dividingBy: 360))
        let normalizedDiff = diff > 180 ? 360 - diff : diff
        return normalizedDiff <= 15.0
    }

    private var compassAccessibilityLabel: String {
        guard let local = localCoordinate, let target = peerCoord else {
            return "La bàn đang chờ tọa độ GPS từ \(peer.identity.displayName)"
        }
        let summary = ProximityMath.formattedProximitySummary(from: local, to: target)
        let lockStatus = isLockedOn
            ? "Đã khóa hướng, đang hướng thẳng về phía trạm"
            : "Xoay máy theo mũi tên để định hướng"
        return "\(peer.identity.displayName), khoảng cách \(summary). \(lockStatus)"
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Header Card
                    VStack(spacing: 6) {
                        Text(peer.identity.displayName)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(MeshTheme.primaryText)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(peer.linkKind == .directP2P ? MeshTheme.emerald : MeshTheme.meshCyan)
                                .frame(width: 8, height: 8)
                            Text(linkDescription)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(MeshTheme.secondaryText)
                        }
                    }
                    .padding(.top, 12)

                    // Compass Radar Display
                    ZStack {
                        // Outer Pulsing Glow on Lock-on
                        Circle()
                            .fill(isLockedOn ? MeshTheme.emerald.opacity(0.18) : Color.white.opacity(0.03))
                            .frame(width: 280, height: 280)
                            .blur(radius: isLockedOn ? 24 : 0)
                            .animation(
                                reduceMotion ? .easeOut(duration: 0.16) : .easeInOut(duration: 0.3),
                                value: isLockedOn
                            )

                        // Outer Dial Ring
                        Circle()
                            .stroke(
                                isLockedOn ? MeshTheme.emerald : Color.white.opacity(0.12),
                                lineWidth: isLockedOn ? 3.5 : 2
                            )
                            .frame(width: 250, height: 250)
                            .shadow(color: isLockedOn ? MeshTheme.emerald.opacity(0.5) : .clear, radius: 12)

                        // Cardinal tick markers
                        ForEach(0..<12) { i in
                            Rectangle()
                                .fill(i % 3 == 0 ? Color.white.opacity(0.5) : Color.white.opacity(0.18))
                                .frame(width: 2, height: i % 3 == 0 ? 12 : 6)
                                .offset(y: -115)
                                .rotationEffect(.degrees(Double(i) * 30))
                        }

                        // Rotating Navigation Arrow
                        if targetBearing != nil {
                            VStack(spacing: 0) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 80, weight: .black))
                                    .foregroundStyle(
                                        isLockedOn
                                            ? LinearGradient(colors: [MeshTheme.emerald, Color.green], startPoint: .top, endPoint: .bottom)
                                            : LinearGradient(colors: [Color.white, Color.gray], startPoint: .top, endPoint: .bottom)
                                    )
                                    .shadow(color: isLockedOn ? MeshTheme.emerald.opacity(0.8) : Color.black.opacity(0.5), radius: 16)
                                Spacer()
                                    .frame(height: 70)
                            }
                            .rotationEffect(.degrees(relativeArrowAngle))
                            .animation(
                                reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.35, dampingFraction: 0.7),
                                value: relativeArrowAngle
                            )
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "location.slash")
                                    .font(.system(size: 40))
                                    .foregroundStyle(MeshTheme.secondaryText)
                                Text("Chưa có GPS")
                                    .font(.caption)
                                    .foregroundStyle(MeshTheme.secondaryText)
                            }
                        }

                        // Center lock-on feedback dot
                        Circle()
                            .fill(isLockedOn ? MeshTheme.emerald : Color.white.opacity(0.3))
                            .frame(width: 14, height: 14)
                    }
                    .frame(height: 280)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(compassAccessibilityLabel)

                    // Precision Metrics
                    if let local = localCoordinate, let target = peerCoord {
                        VStack(spacing: 8) {
                            Text(ProximityMath.formattedProximitySummary(from: local, to: target))
                                .font(.system(size: 26, weight: .heavy, design: .rounded))
                                .foregroundStyle(isLockedOn ? MeshTheme.emerald : MeshTheme.primaryText)

                            if isLockedOn {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                    Text("Đang hướng thẳng về phía trạm")
                                }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(MeshTheme.emerald)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale))
                            } else {
                                Text("Xoay máy theo mũi tên để định hướng")
                                    .font(.footnote)
                                    .foregroundStyle(MeshTheme.secondaryText)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(compassAccessibilityLabel)
                    } else {
                        VStack(spacing: 4) {
                            Text("Đang chờ tọa độ từ trạm...")
                                .font(.subheadline)
                                .foregroundStyle(MeshTheme.secondaryText)
                            Text("Tọa độ GPS sẽ tự động cập nhật qua gói Heartbeat")
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.secondaryText.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 24)
                    }

                    // Telemetry & Altitude / Speed Footer
                    HStack(spacing: 12) {
                        telemetryPill(
                            title: "GÓC PHƯƠNG VỊ",
                            value: targetBearing != nil ? String(format: "%.0f°", targetBearing!) : "--"
                        )
                        telemetryPill(
                            title: "HƯỚNG CẦM MÁY",
                            value: String(format: "%.0f°", effectiveHeading)
                        )
                        if let alt = peerCoord?.altitudeMeters {
                            telemetryPill(
                                title: "ĐỘ CAO",
                                value: String(format: "%.0fm", alt)
                            )
                        }
                    }
                    .padding(.horizontal, 20)

                    // Mock Simulation Slider (for devices without magnetometer or Linux/Simulator testing)
                    VStack(spacing: 8) {
                        Toggle("Mô phỏng Xoay La bàn (Test)", isOn: $useSimulationSlider)
                            .font(.caption)
                            .foregroundStyle(MeshTheme.secondaryText)
                            .tint(MeshTheme.emerald)

                        if useSimulationSlider {
                            HStack {
                                Text("0°")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(MeshTheme.secondaryText)
                                Slider(value: $simulatedHeading, in: 0...360, step: 1) { _ in
                                    onHeadingSliderChanged?(simulatedHeading)
                                }
                                .tint(MeshTheme.emerald)
                                Text("360°")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(MeshTheme.secondaryText)
                            }
                        }
                    }
                    .padding(14)
                    .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(MeshTheme.background)
            .navigationTitle("La Bàn Dò Vị Trí Trạm")
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
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(MeshTheme.background)
        .sensoryFeedback(.impact(weight: .light), trigger: isLockedOn)
    }

    private var linkDescription: String {
        switch peer.linkKind {
        case .directP2P:
            "Kết nối trực tiếp 1-Hop"
        case let .relayedMesh(_, _, hops):
            "\(hops)-Hop qua mạng Mesh"
        case .offlineDTN:
            "Ngoại tuyến (DTN)"
        }
    }

    private func telemetryPill(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(MeshTheme.secondaryText)
            Text(value)
                .font(.subheadline.monospaced().weight(.semibold))
                .foregroundStyle(MeshTheme.primaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(MeshTheme.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
#endif
