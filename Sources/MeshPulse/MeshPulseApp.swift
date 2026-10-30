#if canImport(SwiftUI)
import SwiftUI

@main
struct MeshPulseApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
#else
import MeshCore

public enum MeshPulsePlatformStub: Sendable {}
#endif
