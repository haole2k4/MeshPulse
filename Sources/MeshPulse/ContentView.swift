#if canImport(SwiftUI)
import SwiftUI

public struct ContentView: View {
    @Bindable public var coordinator: MeshCoordinator

    public init(coordinator: MeshCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(spacing: 0) {
            TopStatusHeader(coordinator: coordinator)

            TabView(selection: $coordinator.selectedTab) {
                TopologyRadarTab(coordinator: coordinator)
                    .tabItem {
                        Label(AppTab.topology.title, systemImage: AppTab.topology.systemImage)
                    }
                    .tag(AppTab.topology)

                BroadcastChatTab(coordinator: coordinator)
                    .tabItem {
                        Label(AppTab.broadcast.title, systemImage: AppTab.broadcast.systemImage)
                    }
                    .tag(AppTab.broadcast)

                DirectMessagesTab(coordinator: coordinator)
                    .tabItem {
                        Label(AppTab.direct.title, systemImage: AppTab.direct.systemImage)
                    }
                    .tag(AppTab.direct)

                MeshLabTab(coordinator: coordinator)
                    .tabItem {
                        Label(AppTab.lab.title, systemImage: AppTab.lab.systemImage)
                    }
                    .tag(AppTab.lab)
            }
            #if os(iOS)
            .toolbarBackground(.ultraThinMaterial, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            #endif
        }
        .background(MeshTheme.background.ignoresSafeArea())
        .tint(MeshTheme.p2pGreen)
        .preferredColorScheme(.dark)
    }
}
#endif
