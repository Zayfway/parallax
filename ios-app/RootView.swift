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
    /// Carnet de lieux enregistrés, partagé par la carte.
    @StateObject private var favorites = FavoritesStore()
    /// Boîte de transfert Sources → Installeur : une app touchée dans une source
    /// se dépose ici, et l'Installeur la récupère.
    @StateObject private var inbox = InstallInbox()

    /// Le lancement n'est joué qu'une fois par ouverture, jamais rejoué sur un
    /// simple retour au premier plan : une animation qu'on revoit trop souvent
    /// devient une attente.
    @State private var launching = true

    /// Guide de premier lancement — les préalables (VPN, jumelage) ne sont pas
    /// évidents. Montré une seule fois, puis mémorisé.
    @AppStorage("px.hasOnboarded") private var hasOnboarded = false
    @State private var showOnboarding = false

    /// Onglet courant, piloté aussi par les liens `parallax://` (un point
    /// partagé bascule sur la Carte).
    @State private var selectedTab = 0

    init() {
        let connection = DeviceConnection()
        _connection = StateObject(wrappedValue: connection)
        _pairing = StateObject(wrappedValue: PairingController(connection: connection))
        _location = StateObject(wrappedValue: LocationEngine(connection: connection))
    }

    private var live: Bool { location.state == .simulating }

    var body: some View {
        ZStack {
            tabs

            if launching {
                LaunchView {
                    withAnimation(PX.Motion.settle) { launching = false }
                    if !hasOnboarded { showOnboarding = true }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                hasOnboarded = true
                showOnboarding = false
            }
        }
        // « Revoir le guide » depuis les Réglages remet ce drapeau à false : on
        // rejoue alors le guide en direct, sans attendre le prochain lancement.
        .onChange(of: hasOnboarded) { _, done in
            if !done { showOnboarding = true }
        }
        // Liens entrants : `parallax://locate?lat=…&lon=…` (partage entre
        // appareils, ou site web) bascule sur la Carte et y dépose le point.
        .onOpenURL { url in
            if let coord = LocationLink.coordinate(from: url) {
                location.pendingShare = SharePoint(coordinate: coord)
                selectedTab = 2
            }
        }
        // Une app choisie dans Sources bascule sur l'Installeur, qui se
        // pré-remplit avec son URL.
        .onChange(of: inbox.pending) { _, request in
            if request != nil { selectedTab = 0 }
        }
    }

    private var tabs: some View {
        // iPhone montre les quatre premiers onglets puis un « More » qui regroupe
        // le reste. Les piliers du quotidien — Installer, Sources, Bibliothèque,
        // Carte — restent visibles ; Fichiers, Atelier, Sauvegardes, Jumelage,
        // Certificats et Réglages passent dans « More » (gestion ponctuelle).
        TabView(selection: $selectedTab) {
            SideloadScreen()
                .tabItem { Label("Installer", systemImage: "square.and.arrow.down") }
                .tag(0)

            SourcesScreen()
                .tabItem { Label("Sources", systemImage: "bag") }
                .tag(7)

            LibraryScreen()
                .tabItem { Label("Bibliothèque", systemImage: "square.stack.3d.up") }
                .tag(5)

            MapScreen()
                .tabItem { Label("Carte", systemImage: "location.viewfinder") }
                .tag(2)

            FilesScreen()
                .tabItem { Label("Fichiers", systemImage: "folder") }
                .tag(6)

            AtelierScreen()
                .tabItem { Label("Atelier", systemImage: "wrench.and.screwdriver") }
                .tag(8)

            BackupScreen()
                .tabItem { Label("Sauvegardes", systemImage: "externaldrive.badge.timemachine") }
                .tag(9)

            PairingScreen()
                .tabItem { Label("Jumelage", systemImage: "lock.iphone") }
                .tag(1)

            CertificatesScreen()
                .tabItem { Label("Certificats", systemImage: "checkmark.seal") }
                .tag(3)

            SettingsScreen()
                .tabItem { Label("Réglages", systemImage: "slider.horizontal.3") }
                .tag(4)
        }
        .environmentObject(connection)
        .environmentObject(pairing)
        .environmentObject(location)
        .environmentObject(account)
        .environmentObject(favorites)
        .environmentObject(inbox)
        .tint(live ? PX.Color.signal : PX.Color.azimuth)
        .animation(PX.Motion.settle, value: live)
        .task {
            pairing.observePIN()
            await connection.observeTunnel()
        }
    }
}
