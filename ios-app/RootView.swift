import SwiftUI

/// Coquille de l'app.
///
/// `TabView` + `.tabItem` plutôt que le `Tab` moderne : ce dernier est réservé
/// à iOS 18+, alors que la cible descend à 17.4 — RPPairing fonctionne dès
/// cette version, et rien ne justifie de couper les utilisateurs d'iOS 17 pour
/// une syntaxe d'onglets.
///
/// **La teinte de l'app suit l'état du spoof.** Quand la simulation est active,
/// toute la barre d'onglets passe à l'ambre. C'est le seul endroit où la
/// couleur signature déborde d'un écran : elle devient un signal global,
/// visible même sur l'onglet Installer, pour qu'on ne puisse pas oublier que le
/// GPS ment.
struct RootView: View {

    @StateObject private var connection: DeviceConnection
    @StateObject private var pairing: PairingController
    @StateObject private var location: LocationEngine
    /// Une seule session Apple pour toute l'app : la carte de connexion et
    /// l'écran Certificats la partagent, au lieu d'ouvrir deux connexions.
    @StateObject private var account = AppleAccountModel()

    init() {
        let connection = DeviceConnection()
        _connection = StateObject(wrappedValue: connection)
        _pairing = StateObject(wrappedValue: PairingController(connection: connection))
        _location = StateObject(wrappedValue: LocationEngine(connection: connection))
    }

    private var live: Bool { location.state == .simulating }

    var body: some View {
        TabView {
            SideloadScreen()
                .tabItem { Label("Installer", systemImage: "square.and.arrow.down") }

            PairingScreen()
                .tabItem { Label("Jumelage", systemImage: "lock.iphone") }

            MapScreen()
                .tabItem { Label("Carte", systemImage: "location.viewfinder") }

            CertificatesScreen()
                .tabItem { Label("Certificats", systemImage: "checkmark.seal") }

            SettingsScreen()
                .tabItem { Label("Réglages", systemImage: "slider.horizontal.3") }
        }
        .environmentObject(connection)
        .environmentObject(pairing)
        .environmentObject(location)
        .environmentObject(account)
        .tint(live ? PX.Color.signal : PX.Color.azimuth)
        .animation(PX.Motion.settle, value: live)
        .task {
            pairing.observePIN()
            await connection.observeTunnel()
        }
    }
}
