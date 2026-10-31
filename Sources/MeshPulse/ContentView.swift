#if canImport(SwiftUI)
import SwiftUI

/// Main container view for MeshPulse.
/// - Standard clean iOS NavigationBar and Status Bar (no fake Dynamic Island overlay)
/// - Floating Glass Capsule TabBar attached via `.safeAreaInset(edge: .bottom)` on root screens
/// - TabBar automatically hides when navigating into detail screens (1-1 Chat, etc.)
public struct ContentView: View {
    @Bindable public var coordinator: MeshCoordinator

    public init(coordinator: MeshCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
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
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: coordinator.isDetailViewActive)
        .background(MeshTheme.background.ignoresSafeArea())
        .tint(MeshTheme.emerald)
        .preferredColorScheme(.dark)
    }
}
#endif
