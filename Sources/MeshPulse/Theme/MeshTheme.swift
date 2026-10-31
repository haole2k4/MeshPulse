#if canImport(SwiftUI)
import MeshCore
import SwiftUI

/// Design tokens and Apple Human Interface Guidelines components for MeshPulse (OLED Dark Mode).
public enum MeshTheme {
    // MARK: - Surface Tokens (OLED Tactical Apple Dark)

    /// Primary deep canvas `#05070B`
    public static let background = Color(red: 0x05 / 255.0, green: 0x07 / 255.0, blue: 0x0B / 255.0)
    /// Card container `#141722`
    public static let cardSurface = Color(red: 0x14 / 255.0, green: 0x17 / 255.0, blue: 0x22 / 255.0)
    /// Elevated / interactive control surface `#1E2330`
    public static let elevatedSurface = Color(red: 0x1E / 255.0, green: 0x23 / 255.0, blue: 0x30 / 255.0)
    /// Single elevation separator — 0.8pt crisp specular edge (light catching the material)
    public static let hairlineBorder = Color.white.opacity(0.08)
    public static let strongBorder = Color.white.opacity(0.16)

    // MARK: - Semantic Signal Tokens (Apple Vibrant Palette)

    /// 1-Hop Direct Link (Apple System Green `#30D158`)
    public static let p2pGreen = Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0)
    /// 2+ Hops Relayed Route (Apple System Amber `#FF9F0A`)
    public static let meshAmber = Color(red: 0xFF / 255.0, green: 0x9F / 255.0, blue: 0x0A / 255.0)
    /// Store-and-Forward DTN Outbox / Simulation (Apple System Indigo `#6466F1`)
    public static let dtnIndigo = Color(red: 0x64 / 255.0, green: 0x66 / 255.0, blue: 0xF1 / 255.0)
    /// Emergency SOS Signal & Disconnected Alert (Apple System Red `#FF453A`)
    public static let sosCrimson = Color(red: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0)

    // MARK: - High-Contrast Typography Colors (WCAG AA >= 4.5:1)

    /// Primary foreground `#F5F6F8`
    public static let primaryText = Color(red: 0xF5 / 255.0, green: 0xF6 / 255.0, blue: 0xF8 / 255.0)
    /// Secondary foreground `#9EABB8`
    public static let secondaryText = Color(red: 0x9E / 255.0, green: 0xAB / 255.0, blue: 0xB8 / 255.0)
    /// Cool slate tertiary foreground `#CBD5E1` for colored badges
    public static let badgeText = Color(red: 0xCB / 255.0, green: 0xD5 / 255.0, blue: 0xE1 / 255.0)

    // MARK: - Geometry & Motion Constants (WWDC Fluid Interfaces)

    public static let cardCornerRadius: CGFloat = 16
    public static let minTapDimension: CGFloat = 44
    /// Critically damped response (damping 1.0, response 0.32s)
    public static let fluidSpring = Animation.spring(response: 0.32, dampingFraction: 0.88)

    public static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.16) : fluidSpring
    }

    public static func color(for linkKind: LinkKind) -> Color {
        switch linkKind {
        case .directP2P:
            p2pGreen
        case .relayedMesh:
            meshAmber
        case .offlineDTN:
            dtnIndigo
        }
    }

    public static func color(for deliveryState: DeliveryState) -> Color {
        switch deliveryState {
        case .queuedDTN:
            dtnIndigo
        case .sentDirect, .deliveredAck:
            p2pGreen
        case .relayed:
            meshAmber
        }
    }
}

// MARK: - Apple Pressable Button Style (Instant response on pointer-down)

public struct ApplePressableButtonStyle: ButtonStyle {
    public let scaleDown: CGFloat
    public let pressedOpacity: CGFloat

    public init(scaleDown: CGFloat = 0.96, pressedOpacity: CGFloat = 0.86) {
        self.scaleDown = scaleDown
        self.pressedOpacity = pressedOpacity
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scaleDown : 1.0)
            .opacity(configuration.isPressed ? pressedOpacity : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.76), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ApplePressableButtonStyle {
    public static var applePressable: ApplePressableButtonStyle {
        ApplePressableButtonStyle()
    }

    public static func applePressable(scaleDown: CGFloat = 0.96, pressedOpacity: CGFloat = 0.86) -> ApplePressableButtonStyle {
        ApplePressableButtonStyle(scaleDown: scaleDown, pressedOpacity: pressedOpacity)
    }
}

// MARK: - Surface ViewModifier

public struct MeshCardModifier: ViewModifier {
    public let isElevated: Bool
    public let borderColor: Color
    public let cornerRadius: CGFloat

    public init(
        isElevated: Bool = false,
        borderColor: Color = MeshTheme.hairlineBorder,
        cornerRadius: CGFloat = MeshTheme.cardCornerRadius
    ) {
        self.isElevated = isElevated
        self.borderColor = borderColor
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(isElevated ? MeshTheme.elevatedSurface : MeshTheme.cardSurface)
            }
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: 0.8)
            }
    }
}

extension View {
    public func meshCard(
        elevated: Bool = false,
        borderColor: Color = MeshTheme.hairlineBorder,
        cornerRadius: CGFloat = MeshTheme.cardCornerRadius
    ) -> some View {
        modifier(MeshCardModifier(isElevated: elevated, borderColor: borderColor, cornerRadius: cornerRadius))
    }
}

// MARK: - Reusable Tactical Badges

/// Displays semantic link status (`Direct Link`, `Relayed Route`, or `DTN`) with SF Symbols.
public struct LinkStatusBadge: View {
    public let linkKind: LinkKind

    public init(linkKind: LinkKind) {
        self.linkKind = linkKind
    }

    public var body: some View {
        let accent = MeshTheme.color(for: linkKind)
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .imageScale(.small)
            Text(labelText)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background(accent.opacity(0.14), in: Capsule())
        .overlay {
            Capsule().strokeBorder(accent.opacity(0.28), lineWidth: 0.8)
        }
    }

    private var symbolName: String {
        switch linkKind {
        case .directP2P:
            "dot.radiowaves.left.and.right"
        case .relayedMesh:
            "point.3.connected.trianglepath.dotted"
        case .offlineDTN:
            "tray.and.arrow.down.fill"
        }
    }

    private var labelText: String {
        switch linkKind {
        case .directP2P:
            "1-Hop P2P"
        case let .relayedMesh(_, viaDisplayName, hops):
            "\(hops)-Hop · \(viaDisplayName)"
        case .offlineDTN:
            "Ngoại tuyến DTN"
        }
    }
}

/// Displays the traversed `Route Path` and hop count underneath a chat bubble.
public struct HopPathBadge: View {
    public let routeNames: [String]
    public let hopCount: Int
    public let deliveryState: DeliveryState?
    public let rttMs: Int?

    public init(
        routeNames: [String],
        hopCount: Int,
        deliveryState: DeliveryState? = nil,
        rttMs: Int? = nil
    ) {
        self.routeNames = routeNames
        self.hopCount = hopCount
        self.deliveryState = deliveryState
        self.rttMs = rttMs
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
                .imageScale(.small)
                .foregroundStyle(accentColor)

            if !routeNames.isEmpty {
                Text(routeNames.joined(separator: " → "))
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text("\(hopCount)H")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(accentColor)

            if let rttMs {
                Text("\(rttMs)ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MeshTheme.secondaryText)
            }

            if let deliveryState {
                Text(deliveryLabel(for: deliveryState))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(MeshTheme.color(for: deliveryState))
            }
        }
        .foregroundStyle(MeshTheme.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(MeshTheme.elevatedSurface.opacity(0.85), in: Capsule())
        .overlay {
            Capsule().strokeBorder(accentColor.opacity(0.24), lineWidth: 0.8)
        }
    }

    private var accentColor: Color {
        if let deliveryState, deliveryState == .queuedDTN {
            return MeshTheme.dtnIndigo
        }
        return hopCount > 1 ? MeshTheme.meshAmber : MeshTheme.p2pGreen
    }

    private var iconName: String {
        if let deliveryState, deliveryState == .queuedDTN {
            return "clock.arrow.circlepath"
        }
        return hopCount > 1 ? "point.3.connected.trianglepath.dotted" : "dot.radiowaves.left.and.right"
    }

    private func deliveryLabel(for state: DeliveryState) -> String {
        switch state {
        case .queuedDTN:
            "Lưu DTN"
        case .sentDirect:
            "Đã gửi"
        case .relayed:
            "Bắc cầu"
        case .deliveredAck:
            "ACK"
        }
    }
}

/// Interactive `>= 44pt` GPS coordinate chip that deep-links into Apple Maps (`maps://?ll=...&q=...`).
public struct GeoLocationLinkChip: View {
    public let coordinate: GeoCoordinate
    public let label: String
    public let tint: Color

    @Environment(\.openURL) private var openURL

    public init(
        coordinate: GeoCoordinate,
        label: String,
        tint: Color = MeshTheme.p2pGreen
    ) {
        self.coordinate = coordinate
        self.label = label
        self.tint = tint
    }

    public var body: some View {
        Button {
            if let url = appleMapsURL {
                openURL(url)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(formattedCoords)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(MeshTheme.primaryText)
                    Text("Sai số ±\(Int(coordinate.accuracyMeters.rounded()))m · Mở Bản đồ")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(MeshTheme.secondaryText)
                }

                Spacer(minLength: 4)

                Image(systemName: "arrow.up.right.square.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(minHeight: MeshTheme.minTapDimension)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint.opacity(0.32), lineWidth: 0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.applePressable)
        .accessibilityLabel("Vị trí GPS \(formattedCoords), sai số \(Int(coordinate.accuracyMeters.rounded())) mét")
        .accessibilityHint("Chạm để mở vị trí trong Apple Maps")
    }

    private var formattedCoords: String {
        let lat = coordinate.latitude.formatted(.number.precision(.fractionLength(5)))
        let lon = coordinate.longitude.formatted(.number.precision(.fractionLength(5)))
        return "\(lat), \(lon)"
    }

    private var appleMapsURL: URL? {
        let encodedTitle = label.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "MeshPulse"
        return URL(string: "maps://?ll=\(coordinate.latitude),\(coordinate.longitude)&q=\(encodedTitle)")
    }
}

// MARK: - Extension for RoutingStrategy SF Symbols

extension RoutingStrategy {
    public var systemImage: String {
        switch self {
        case .managedFlooding:
            "point.3.connected.trianglepath.dotted"
        case .sprayAndWait:
            "arrow.triangle.branch"
        case .epidemic:
            "arrow.triangle.2.circlepath"
        }
    }
}
#endif
