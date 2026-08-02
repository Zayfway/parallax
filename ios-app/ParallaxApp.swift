import SwiftUI
import UIKit

@main
struct ParallaxApp: App {
    init() {
        // Premier appel, avant tout le reste : sans lui, les traces d'idevice
        // disparaissent et le débogage sur appareil devient impossible.
        LogBridge.install()
        Self.styleBars()
    }

    /// Barre d'onglets en verre, teintée nuit pour rester cohérente avec le
    /// canvas. On ne touche PAS à la couleur des items : c'est SwiftUI (`.tint`)
    /// qui la pilote, pour que la bascule à l'ambre — position simulée active —
    /// continue de déborder sur toute la barre.
    private static func styleBars() {
        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        tab.backgroundColor = UIColor(PX.Color.night).withAlphaComponent(0.62)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(PX.Color.azimuth)
        }
    }
}
