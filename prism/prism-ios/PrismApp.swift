import SwiftUI
import UIKit

@main
struct PrismApp: App {
    init() {
        LogBridge.install()
        Self.styleBars()
    }

    // La barre d'onglets n'est PAS teintée à la main pour ses items — c'est
    // `.tint` en SwiftUI qui pilote, pour que la bascule « écriture active »
    // déborde en ambre sur toute la barre (règle 1).
    private static func styleBars() {
        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        tab.backgroundColor = UIColor(PR.Color.night).withAlphaComponent(0.62)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(PR.Color.azimuth)
        }
    }
}
