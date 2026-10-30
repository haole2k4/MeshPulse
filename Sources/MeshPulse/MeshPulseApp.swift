#if canImport(SwiftUI)
import SwiftUI

@main
struct MeshPulseApp: App {
    @State private var coordinator = MeshCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator)
                .preferredColorScheme(.dark)
        }
    }
}
#else
import MeshCore

public enum MeshPulsePlatformStub: Sendable {}
#endif
