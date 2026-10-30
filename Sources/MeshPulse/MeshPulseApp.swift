#if canImport(SwiftUI)
import SwiftUI

@main
struct MeshPulseApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator: MeshCoordinator = {
        #if canImport(MultipeerConnectivity) && canImport(CryptoKit) && canImport(Security) && canImport(CoreLocation)
        return MeshCoordinator(
            startInMockMode: true,
            transport: MultipeerTransport(),
            sealer: CryptoKitSealer.loadOrCreate(),
            locationProvider: LocationProvider()
        )
        #elseif canImport(MultipeerConnectivity)
        return MeshCoordinator(startInMockMode: true, transport: MultipeerTransport())
        #else
        return MeshCoordinator(startInMockMode: true)
        #endif
    }()

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, newPhase in
            coordinator.handleScenePhase(newPhase)
        }
    }
}
#else
import MeshCore

public enum MeshPulsePlatformStub: Sendable {}
#endif
