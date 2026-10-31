#if canImport(SwiftUI)
import SwiftUI

/// Floating Glass Capsule TabBar for MeshPulse (Meshtastic Style).
/// - Width stretches across screen: frame(maxWidth: .infinity) with padding(.horizontal, 20) and padding(.bottom, 8)
/// - Height: 64pt
/// - Displays BOTH Icon (size 20pt) and Text label (.font(.caption2)) for ALL tabs
/// - Selected tab has rounded Capsule() background (.white.opacity(0.15)) wrapping icon & label with matchedGeometryEffect
/// - Whole TabBar uses .background(.ultraThinMaterial), .clipShape(Capsule()), and .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
public struct FloatingGlassTabBar: View {
    @Bindable public var coordinator: MeshCoordinator
    @Namespace private var tabAnimation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(coordinator: MeshCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                tabButton(for: tab)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        }
        .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 5)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Individual Tab Button

    private func tabButton(for tab: AppTab) -> some View {
        let isSelected = coordinator.selectedTab == tab

        return Button {
            guard coordinator.selectedTab != tab else { return }
            let animation = MeshTheme.animation(reduceMotion: reduceMotion)
            withAnimation(animation) {
                coordinator.selectedTab = tab
            }
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 20, weight: isSelected ? .bold : .medium))
                        .frame(width: 26, height: 26)

                    // Message Tab Notification Badge (Red badge like Meshtastic)
                    if tab == .messages && coordinator.unreadMessageCount > 0 {
                        Text("\(coordinator.unreadMessageCount)")
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.white)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(MeshTheme.sosCrimson, in: Circle())
                            .offset(x: 10, y: -4)
                    }
                }

                Text(tab.title)
                    .font(.caption2.weight(isSelected ? .bold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? MeshTheme.emerald : MeshTheme.secondaryText)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                        .matchedGeometryEffect(id: "ACTIVE_TAB_PILL", in: tabAnimation)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: coordinator.selectedTab)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }
}
#endif
