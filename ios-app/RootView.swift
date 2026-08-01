import SwiftUI

/// Coquille de l'app.
///
/// Les trois premiers onglets reprennent la structure d'origine ; **Carte** est
/// l'ajout du module GPS.
///
/// Jumelage reste un onglet à part plutôt qu'une étape enfouie dans Installer,
/// parce que le fichier RPPairing sert désormais **aux deux** modules. L'y
/// enterrer laisserait croire qu'il ne concerne que le sideloading, alors qu'un
/// utilisateur venu uniquement pour le GPS en a tout autant besoin.
struct RootView: View {

    @StateObject private var connection: DeviceConnection
    @StateObject private var pairing: PairingController
    @StateObject private var location: LocationEngine

    init() {
        let connection = DeviceConnection()
        _connection = StateObject(wrappedValue: connection)
        _pairing = StateObject(wrappedValue: PairingController(connection: connection))
        _location = StateObject(wrappedValue: LocationEngine(connection: connection))
    }

    var body: some View {
        TabView {
            SideloadScreen()
                .tabItem { Label("Installer", systemImage: "square.and.arrow.down") }
            PairingScreen()
                .tabItem { Label("Jumelage", systemImage: "lock.iphone") }
            MapScreen()
                .tabItem { Label("Carte", systemImage: "location.viewfinder") }
            SettingsScreen()
                .tabItem { Label("Réglages", systemImage: "slider.horizontal.3") }
        }
        .environmentObject(connection)
        .environmentObject(pairing)
        .environmentObject(location)
        .tint(location.state == .simulating ? PX.Color.signal : PX.Color.azimuth)
        .task {
            pairing.observePIN()
            await connection.observeTunnel()
        }
    }
}
