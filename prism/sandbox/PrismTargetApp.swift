import SwiftUI

// Petite app cible pour tester l'agent Prism : des valeurs typées à des
// adresses stables (UnsafeMutablePointer), relues en continu. Injecte l'agent
// Prism dedans, scanne une valeur, édite-la — elle change ici en direct.
@main
struct PrismTargetApp: App {
    var body: some Scene {
        WindowGroup { TargetView() }
    }
}
