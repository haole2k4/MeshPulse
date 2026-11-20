#if canImport(SwiftUI)
import SwiftUI

/// Main container view for MeshPulse.
/// - Standard clean iOS NavigationBar and Status Bar
/// - In-App Live Transfer Pill overlay at the top edge when media chunk transfers are active
/// - Floating Glass Capsule TabBar attached via `.safeAreaInset(edge: .bottom)` on root screens
/// - TabBar automatically hides when navigating into detail screens (1-1 Chat, etc.)
public struct ContentView: View {
    @Bindable public var coordinator: MeshCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(coordinator: MeshCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        let activeTransfer = MediaTransferActivityManager.shared.primaryActiveDisplay
        let activeCount = MediaTransferActivityManager.shared.activeDisplays.count

        Group {
            switch coordinator.selectedTab {
            case .messages:
                MessagesTab(coordinator: coordinator)
            case .nodes:
                NodesTab(coordinator: coordinator)
            case .map:
                MapTab(coordinator: coordinator)
            case .lab:
                MeshLabTab(coordinator: coordinator)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !coordinator.isDetailViewActive {
                FloatingGlassTabBar(coordinator: coordinator)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if let activeTransfer {
                LiveTransferPillView(
                    transfer: activeTransfer,
                    additionalCount: max(0, activeCount - 1),
                    reduceMotion: reduceMotion
                )
                .padding(.top, 4)
                .padding(.horizontal, 16)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .top)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.92, anchor: .top))
                )
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: coordinator.isDetailViewActive)
        .animation(MeshTheme.animation(reduceMotion: reduceMotion), value: activeTransfer)
        .background(MeshTheme.background.ignoresSafeArea())
        .tint(MeshTheme.emerald)
        .preferredColorScheme(.dark)
    }
}

// MARK: - In-App Live Transfer Pill (Dynamic Island-Inspired)

private struct LiveTransferPillView: View {
    let transfer: ActiveTransferDisplay
    let additionalCount: Int
    let reduceMotion: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(MeshTheme.emerald)
                .symbolEffect(.pulse, isActive: !transfer.isComplete && !reduceMotion)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(transfer.filename)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MeshTheme.primaryText)
                        .lineLimit(1)

                    if additionalCount > 0 {
                        Text("+\(additionalCount)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(MeshTheme.emerald)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(MeshTheme.emerald.opacity(0.16), in: Capsule())
                    }
                }

                Text(transfer.statusNote)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MeshTheme.secondaryText)
                    .lineLimit(1)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.14))
                        Capsule()
                            .fill(MeshTheme.emerald)
                            .frame(width: max(4, proxy.size.width * transfer.progress))
                    }
                }
                .frame(height: 3.5)
            }
            .frame(minWidth: 136, idealWidth: 176, maxWidth: 210, alignment: .leading)

            Text("\(transfer.percentComplete)%")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(MeshTheme.emerald)
                .contentTransition(.numericText())
                .frame(minWidth: 36, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            if reduceTransparency {
                Capsule()
                    .fill(MeshTheme.cardSurface)
            } else {
                Capsule()
                    .fill(.ultraThinMaterial)
            }
        }
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(
                    reduceTransparency ? MeshTheme.strongBorder : Color.white.opacity(0.16),
                    lineWidth: reduceTransparency ? 1.0 : 0.75
                )
        }
        .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 6)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(transfer.filename), \(transfer.statusNote), \(transfer.percentComplete) phần trăm")
    }

    private var symbolName: String {
        if transfer.isComplete {
            return "checkmark.circle.fill"
        }
        return transfer.isOutgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
    }
}
#endif
