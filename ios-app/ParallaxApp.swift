import SwiftUI

@main
struct ParallaxApp: App {
    init() {
        // Premier appel, avant tout le reste : sans lui, les traces d'idevice
        // disparaissent et le débogage sur appareil devient impossible.
        LogBridge.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(PX.Color.azimuth)
        }
    }
}
