import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
// LANCEMENT
//
// Une app qui s'ouvre sur un onglet froid n'a pas de première impression. Mais
// une animation de lancement qui fait attendre en a une mauvaise — c'est le
// piège classique, et il coûte cher parce qu'on la voit à *chaque* ouverture.
//
// Celle-ci dure 1,1 s et raconte quelque chose : les deux visées naissent
// confondues au centre, puis **s'écartent**. C'est la parallaxe elle-même, en
// un geste. Quand l'écart est établi, l'app est là.
//
// L'ambre apparaît ici et c'est le seul écart à la règle, assumé : cette vue
// n'est pas une interface mais l'identité de l'app, la même que son icône. Dès
// que l'interface prend la main, l'ambre redevient exclusivement « position
// simulée active ».
// ═══════════════════════════════════════════════════════════════════════════

struct LaunchView: View {

    /// Passe à `true` quand l'animation est finie. C'est `RootView` qui décide
    /// quoi en faire ; cette vue ne connaît pas la suite.
    let onFinished: () -> Void

    @State private var separation: CGFloat = 0
    @State private var ringScale: CGFloat = 0.6
    @State private var ringOpacity: Double = 0
    @State private var titleShown = false
    @State private var haloBreathing = false

    private let spread: CGFloat = 46

    var body: some View {
        ZStack {
            PX.Color.canvas

            VStack(spacing: PX.Space.loose) {
                symbol
                wordmark
            }
        }
        .task { await run() }
    }

    // MARK: - Le symbole

    private var symbol: some View {
        ZStack {
            // Halo ambré, la respiration lente d'un état persistant.
            Circle()
                .fill(PX.Color.signal.opacity(0.18))
                .frame(width: 96, height: 96)
                .blur(radius: 26)
                .scaleEffect(haloBreathing ? 1.18 : 0.92)
                .offset(x: separation)

            // La ligne de base : la mesure entre les deux points de vue.
            Capsule()
                .fill(PX.Color.ink.opacity(0.16))
                .frame(width: max(separation * 2, 1), height: 1.5)

            sight(tint: PX.Color.azimuth, filled: false)
                .offset(x: -separation)

            sight(tint: PX.Color.signal, filled: true)
                .offset(x: separation)
        }
        .frame(height: 132)
        .scaleEffect(ringScale)
        .opacity(ringOpacity)
    }

    private func sight(tint: Color, filled: Bool) -> some View {
        ZStack {
            Circle()
                .strokeBorder(tint, lineWidth: 3)
                .frame(width: 54, height: 54)

            // Quatre repères : ça se lit comme une visée, pas comme un cercle.
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: 11)
                    .offset(y: -34)
                    .rotationEffect(.degrees(Double(index) * 90))
            }

            Circle()
                .fill(tint)
                .frame(width: filled ? 15 : 11, height: filled ? 15 : 11)
        }
    }

    // MARK: - Le nom

    private var wordmark: some View {
        VStack(spacing: PX.Space.hair) {
            Text("PARALLAX")
                .font(PX.Font.display(25, .heavy))
                .tracking(titleShown ? 7 : 1)
                .foregroundStyle(PX.Color.ink)

            Text("le même point, deux points de vue")
                .font(PX.Font.body(11.5))
                .foregroundStyle(PX.Color.inkFaint)
                .opacity(titleShown ? 1 : 0)
        }
        .opacity(titleShown ? 1 : 0)
    }

    // MARK: - La séquence

    /// Trois temps : les visées arrivent confondues, elles s'écartent, le nom
    /// se pose. Les durées passent par le vocabulaire de `PX.Motion`.
    private func run() async {
        withAnimation(PX.Motion.settle) {
            ringOpacity = 1
            ringScale = 1
        }

        try? await Task.sleep(for: .milliseconds(180))

        // Le geste qui porte tout : l'écart se crée.
        withAnimation(PX.Motion.acquire) { separation = spread }
        withAnimation(PX.Motion.breathe) { haloBreathing = true }

        try? await Task.sleep(for: .milliseconds(260))
        withAnimation(PX.Motion.settle) { titleShown = true }

        try? await Task.sleep(for: .milliseconds(660))
        onFinished()
    }
}
