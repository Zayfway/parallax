import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
// PARALLAX — système de design
//
// La parallaxe est le déplacement apparent d'un objet selon le point d'où on
// l'observe. C'est ce que fait l'app : l'appareil déclare une position qui
// dépend de qui l'interroge.
//
// Champ froid indigo, et une seule chaleur — l'ambre — réservée à un usage
// unique : **position simulée active**. Elle n'apparaît nulle part ailleurs.
// Quand l'écran devient chaud, c'est que le GPS ment. Ça s'apprend en une
// session, sans légende, et c'est la contrainte qui structure tout le reste.
//
// ── SUR LE VERRE ──────────────────────────────────────────────────────────
// `.glassEffect()` est une API iOS 26. La cible du projet est 17.4, pour que
// les utilisateurs d'iOS 17–25 gardent le module GPS via un fichier de
// jumelage importé. Le verre est donc reconstruit à la main :
//
//   1. un matériau système flouté      → la réfraction
//   2. un voile teinté par-dessus      → la profondeur
//   3. un liseré clair en haut         → l'arête éclairée
//   4. une ombre portée douce          → le détachement
//
// La couche 3 est celle qu'on oublie, et c'est elle qui sépare « verre » de
// « rectangle flou ».
// ═══════════════════════════════════════════════════════════════════════════

enum PX {

    // MARK: - Couleur

    enum Color {
        /// Canvas. Pas noir pur : un matériau translucide n'a rien à réfracter
        /// sur du #000 et s'effondre en gris plat.
        static let night = SwiftUI.Color(hex: 0x0A0D18)
        static let abyss = SwiftUI.Color(hex: 0x131829)
        static let strata = SwiftUI.Color(hex: 0x1C2338)
        static let horizon = SwiftUI.Color(hex: 0x2A3352)

        /// Interactif primaire. Pervenche plutôt que le bleu système :
        /// reconnaissable comme appartenant à cette app, sans quitter le
        /// registre Apple.
        static let azimuth = SwiftUI.Color(hex: 0x7C8CFF)
        /// ★ Signature. Position simulée active, et rien d'autre.
        static let signal = SwiftUI.Color(hex: 0xF5A65B)
        static let verdant = SwiftUI.Color(hex: 0x4ADE9B)
        static let alert = SwiftUI.Color(hex: 0xFF6B6B)

        static let ink = SwiftUI.Color(hex: 0xF2F4FF)
        static let inkMuted = SwiftUI.Color(hex: 0x9AA3C4)
        static let inkFaint = SwiftUI.Color(hex: 0x5A6488)

        /// Fond d'écran : dégradé radial haut + voile nocturne.
        /// Donne au verre quelque chose à réfracter, sinon tout le système
        /// s'aplatit.
        static var canvas: some View {
            ZStack {
                night
                RadialGradient(
                    colors: [SwiftUI.Color(hex: 0x1D2447).opacity(0.9), .clear],
                    center: .init(x: 0.5, y: -0.1),
                    startRadius: 0, endRadius: 620
                )
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Typographie

    /// **Rounded** pour ce qui s'adresse à l'humain — la face la plus
    /// chaleureuse du système, sous-utilisée hors watchOS.
    /// **Mono** pour ce que la machine affirme : coordonnées, IP, empreintes.
    /// La règle est absolue et porte du sens : si c'est en mono, ça vient de
    /// l'appareil, pas de nous.
    enum Font {
        static func display(_ size: CGFloat, _ weight: SwiftUI.Font.Weight = .bold) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .rounded)
        }
        static func body(_ size: CGFloat = 15, _ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .rounded)
        }
        static func mono(_ size: CGFloat = 13, _ weight: SwiftUI.Font.Weight = .medium) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
    }

    // MARK: - Géométrie

    /// Rayons concentriques : un contenu à 12 dans un conteneur à 20 avec 8 de
    /// marge donne des courbes parallèles. C'est la règle qu'Apple applique au
    /// matériel comme à ses feuilles, et son absence est exactement ce qui fait
    /// qu'une interface « sent le template ».
    enum Radius {
        static let sheet: CGFloat = 28
        static let card: CGFloat = 20
        static let control: CGFloat = 14
        static let chip: CGFloat = 10
    }

    enum Space {
        static let hair: CGFloat = 4
        static let tight: CGFloat = 8
        static let snug: CGFloat = 12
        static let base: CGFloat = 16
        static let loose: CGFloat = 24
        static let wide: CGFloat = 32
    }

    // MARK: - Motion

    /// Un vocabulaire nommé par **intention**, pas par courbe. Quand chaque
    /// animation choisit ses propres chiffres, l'ensemble part en vrille sans
    /// qu'on sache pourquoi ; ici on ne choisit qu'entre quatre gestes.
    enum Motion {
        /// Réponse immédiate à un doigt : bouton, segment, bascule.
        static let tap = Animation.spring(response: 0.28, dampingFraction: 0.72)
        /// Apparition ou changement d'état d'un panneau.
        static let settle = Animation.spring(response: 0.5, dampingFraction: 0.82)
        /// Le moment orchestré : acquisition d'un point.
        static let acquire = Animation.spring(response: 0.62, dampingFraction: 0.58)
        /// Respiration lente d'un état persistant.
        static let breathe = Animation.easeInOut(duration: 2.2).repeatForever(autoreverses: true)

        /// Décalage en cascade pour une pile d'éléments.
        /// 45 ms : assez pour lire la séquence, trop court pour attendre.
        static func stagger(_ index: Int) -> Animation {
            settle.delay(Double(index) * 0.045)
        }
    }
}

// MARK: - Verre

/// Carte en verre. Voir la note sur les quatre couches en tête de fichier.
struct GlassCard: ViewModifier {
    var radius: CGFloat = PX.Radius.card
    var tint: Color = PX.Color.abyss
    var emphasis: Bool = false

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape(radius))
            .background(shape(radius).fill(tint.opacity(emphasis ? 0.74 : 0.52)))
            .overlay(
                // L'arête éclairée. Sans elle, ce n'est qu'un rectangle flou.
                shape(radius).strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.16), .white.opacity(0.05), .white.opacity(0.015)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
            )
            .shadow(color: .black.opacity(0.42), radius: 18, y: 8)
    }

    private func shape(_ r: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: r, style: .continuous)
    }
}

extension View {
    func glassCard(
        radius: CGFloat = PX.Radius.card,
        tint: Color = PX.Color.abyss,
        emphasis: Bool = false
    ) -> some View {
        modifier(GlassCard(radius: radius, tint: tint, emphasis: emphasis))
    }

    /// Halo ambré. Réservé à l'état actif du spoof.
    func signalGlow(_ active: Bool, radius: CGFloat = 18) -> some View {
        shadow(color: active ? PX.Color.signal.opacity(0.5) : .clear, radius: radius, y: 3)
    }

    /// Entrée en cascade : chaque carte glisse et se révèle avec un léger retard.
    func appear(_ index: Int, _ shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .animation(PX.Motion.stagger(index), value: shown)
    }
}

// MARK: - Contrôles

/// Bouton principal. Un seul par écran, jamais deux.
struct ProminentButtonStyle: ButtonStyle {
    var tint: Color = PX.Color.azimuth
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PX.Font.display(17, .semibold))
            .foregroundStyle(enabled ? Color.white : PX.Color.inkFaint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(
                RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
                    .fill(enabled
                          ? LinearGradient(colors: [tint, tint.opacity(0.76)],
                                           startPoint: .top, endPoint: .bottom)
                          : LinearGradient(colors: [PX.Color.strata, PX.Color.strata],
                                           startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
                    .strokeBorder(.white.opacity(enabled ? 0.22 : 0.04), lineWidth: 0.9)
            )
            .shadow(color: enabled ? tint.opacity(0.38) : .clear, radius: 18, y: 7)
            .scaleEffect(configuration.isPressed ? 0.972 : 1)
            .animation(PX.Motion.tap, value: configuration.isPressed)
            // Retour haptique au relâchement : le geste se termine dans la main
            // avant de se terminer à l'écran.
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    /// Teinte du libellé. Neutre par défaut ; `PX.Color.alert` pour une action
    /// destructive. Le châssis, lui, ne change pas : c'est le mot qui porte
    /// l'avertissement, pas le bouton entier — sinon il rivalise avec l'action
    /// principale de l'écran.
    var tint: Color = PX.Color.inkMuted

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PX.Font.display(14, .medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
                    .strokeBorder(PX.Color.horizon, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(PX.Motion.tap, value: configuration.isPressed)
    }
}

/// Champ de saisie. Le libellé flotte au-dessus plutôt qu'en placeholder : un
/// placeholder disparaît à la frappe, et qui revient sur un formulaire à demi
/// rempli ne sait plus quel champ est lequel.
struct FieldStyle: ViewModifier {
    let label: String
    var mono: Bool = false
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: PX.Space.hair + 2) {
            Text(label.uppercased())
                .font(PX.Font.mono(10, .semibold))
                .tracking(0.9)
                .foregroundStyle(focused ? PX.Color.azimuth : PX.Color.inkFaint)

            content
                .font(mono ? PX.Font.mono(15) : PX.Font.body(16))
                .foregroundStyle(PX.Color.ink)
                .focused($focused)
                .padding(.horizontal, PX.Space.base)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
                        .fill(PX.Color.night.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
                        .strokeBorder(focused ? PX.Color.azimuth.opacity(0.6) : PX.Color.horizon,
                                      lineWidth: focused ? 1.4 : 1)
                )
        }
        .animation(PX.Motion.tap, value: focused)
    }
}

extension View {
    func field(_ label: String, mono: Bool = false) -> some View {
        modifier(FieldStyle(label: label, mono: mono))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(PX.Font.mono(10, .semibold))
            .tracking(1.0)
            .foregroundStyle(PX.Color.inkFaint)
    }
}

struct Tag: View {
    let text: String, color: Color, icon: String
    init(_ text: String, color: Color, icon: String) {
        self.text = text; self.color = color; self.icon = icon
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(PX.Font.display(11, .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.14)))
        .overlay(Capsule().strokeBorder(color.opacity(0.30), lineWidth: 1))
    }
}

// MARK: - Élément signature

/// La bande d'instruments.
///
/// L'élément par lequel l'app doit être reconnue. Présente sur chaque écran, en
/// mono à chiffres tabulaires, elle affiche en continu ce que l'appareil
/// déclare. Un instrument de bord, pas un badge de statut.
///
/// Elle existe parce que le sujet de l'app est précisément *ce que l'appareil
/// affirme*. Rendre cette affirmation visible en permanence, dans une police
/// qui signale « valeur machine », c'est traduire la thèse du produit en
/// interface plutôt que de la décrire dans un texte d'accueil.
struct InstrumentStrip: View {
    let latitude: Double?
    let longitude: Double?
    let sessionLabel: String
    let live: Bool

    @State private var breathing = false

    var body: some View {
        HStack(spacing: PX.Space.snug) {
            Circle()
                .fill(live ? PX.Color.signal : PX.Color.inkFaint)
                .frame(width: 7, height: 7)
                .scaleEffect(live && breathing ? 1.45 : 1)
                .signalGlow(live, radius: 10)

            Text(coordinateText)
                .font(PX.Font.mono(13, .semibold))
                .monospacedDigit()
                .foregroundStyle(live ? PX.Color.signal : PX.Color.inkMuted)
                // Les chiffres roulent au lieu de sauter — c'est ce qui fait
                // lire la bande comme un instrument plutôt qu'un label.
                .contentTransition(.numericText())

            Spacer(minLength: PX.Space.tight)

            Text(sessionLabel.uppercased())
                .font(PX.Font.mono(10, .semibold))
                .tracking(0.8)
                .foregroundStyle(statusTint)
                .contentTransition(.opacity)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(statusTint.opacity(0.12))
                        .overlay(Capsule().strokeBorder(statusTint.opacity(0.26), lineWidth: 0.8))
                )
                // La pastille respire quand quelque chose est vivant, et reste
                // inerte sinon. C'est le seul mouvement de la bande, donc il
                // se remarque sans avoir à être lu.
                .shadow(color: statusTint.opacity(statusGlows && breathing ? 0.45 : 0),
                        radius: 8)
        }
        .padding(.horizontal, PX.Space.base)
        .padding(.vertical, 11)
        .glassCard(radius: PX.Radius.chip)
        .animation(PX.Motion.settle, value: live)
        .animation(PX.Motion.settle, value: sessionLabel)
        .onAppear { withAnimation(PX.Motion.breathe) { breathing = true } }
    }

    /// Teinte de la pastille d'état, déduite du libellé. Vert quand quelque
    /// chose tient, rouge quand ça manque, pervenche pendant, neutre au repos.
    /// Jamais d'ambre : elle est réservée au point et aux coordonnées.
    private var statusTint: Color {
        let text = sessionLabel.uppercased()
        if text.contains("OK") || text.contains("ÉTABLI") || text.contains("EMPLACEMENT") {
            return PX.Color.verdant
        }
        if text.contains("OFF") || text.contains("SUBNET") || text.contains("ERREUR")
            || text.contains("HORS LIGNE") {
            return PX.Color.alert
        }
        if text.contains("…") || text.contains("LECTURE") { return PX.Color.azimuth }
        return PX.Color.inkFaint
    }

    private var statusGlows: Bool {
        statusTint == PX.Color.verdant || statusTint == PX.Color.azimuth
    }

    private var coordinateText: String {
        guard let latitude, let longitude else { return "—— .————  ·  —— .————" }
        return String(format: "%+09.5f · %+010.5f", latitude, longitude)
    }
}

// MARK: - Utilitaire

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
