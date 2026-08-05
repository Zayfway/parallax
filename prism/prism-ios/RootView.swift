import SwiftUI

struct RootView: View {
    @StateObject private var engine = ScanEngine()
    @State private var tab = 0

    var body: some View {
        // TabView + .tabItem/.tag (pas le `Tab` moderne : cible iOS 17.4).
        TabView(selection: $tab) {
            ScanScreen()
                .tabItem { Label("Mémoire", systemImage: "scope") }
                .tag(0)
            RegionsScreen()
                .tabItem { Label("Régions", systemImage: "square.grid.3x3") }
                .tag(1)
        }
        .environmentObject(engine)
        // Le seul débordement global : ambre dès qu'une écriture est active.
        .tint(engine.writing ? PR.Color.signal : PR.Color.azimuth)
        .animation(PR.Motion.settle, value: engine.writing)
    }
}
