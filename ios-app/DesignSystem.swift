import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
// PARALLAX — système de design
//
// Le nom : la parallaxe est le déplacement apparent d'un objet selon le point
// d'où on l'observe. C'est littéralement ce que fait l'app — l'appareil déclare
// une position qui dépend de qui l'interroge. Le mot est court, technique sans
// être obscur, et non pris dans cet écosystème.
//
// La direction visuelle vient du sujet plutôt que d'un thème sombre générique :
// les couleurs du crépuscule civil vu d'altitude. Champ froid indigo, et une
// seule chaleur — l'ambre vapeur de sodium de la ligne d'horizon — réservée à
// un usage unique : l'état « position simulée active ».
//
// Cette contrainte est le cœur du système. L'ambre n'apparaît nulle part
// ailleurs. Quand l'écran devient chaud, c'est que le GPS ment. Aucune légende
// n'est nécessaire pour l'apprendre : ça se retient en une session.
// ═══════════════════════════════════════════════════════════════════════════

enum PX {

    // MARK: - Couleur

    enum Color {
        /// Canvas. Volontairement pas noir pur : le matériau translucide d'iOS 26+
        /// n'a rien à réfracter sur du #000 et s'effondre en gris plat.
        static let night = SwiftUI.Color(hex: 0x0A0D18)
        /// Surfaces surélevées — cartes, feuilles, barres.
        static let abyss = SwiftUI.Color(hex: 0x131829)
        /// Surface d'un cran au-dessus, pour l'imbrication.
        static let strata = SwiftUI.Color(hex: 0x1C2338)
        /// Filets et séparateurs. Jamais du blanc à opacité — ça grisaille.
        static let horizon = SwiftUI.Color(hex: 0x2A3352)

        /// Interactif primaire. Pervenche plutôt que le bleu système : reconnaissable
        /// comme appartenant à cette app, sans quitter le registre Apple.
        static let azimuth = SwiftUI.Color(hex: 0x7C8CFF)
        /// ★ Signature. Position simulée active, et rien d'autre. Jamais décoratif.
        static let signal = SwiftUI.Color(hex: 0xF5A65B)
        /// Jumelé, signé, installé.
        static let verdant = SwiftUI.Color(hex: 0x4ADE9B)
        /// Échec exploitable par l'utilisateur.
        static let alert = SwiftUI.Color(hex: 0xFF6B6B)

        static let ink = SwiftUI.Color(hex: 0xF2F4FF)
        static let inkMuted = SwiftUI.Color(hex: 0x9AA3C4)
        static let inkFaint = SwiftUI.Color(hex: 0x5A6488)
    }

    // MARK: - Typographie

    /// Deux rôles, une raison à chacun.
    ///
    /// **Rounded** pour tout ce qui s'adresse à l'humain. C'est la face la plus
    /// chaleureuse du système Apple, sous-utilisée hors watchOS, et elle
    /// distingue immédiatement l'app d'un empilement de contrôles par défaut.
    ///
    /// **Mono** pour tout ce que la machine affirme : coordonnées, IP, UDID,
    /// empreintes, journaux. La règle est absolue et porte du sens — si c'est en
    /// mono, ça vient de l'appareil et non de nous. Chiffres tabulaires partout,
    /// sinon les valeurs qui défilent font vibrer la mise en page.
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

    /// Rayons concentriques. Un contenu à 12 dans un conteneur à 20 avec 8 de
    /// marge donne des courbes parallèles ; c'est la règle qu'Apple applique au
    /// matériel et à ses propres feuilles, et son absence est exactement ce qui
    /// fait qu'une interface « sent le template ».
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

    /// Un seul moment orchestré dans toute l'app : l'acquisition d'un point.
    /// Le reste est sobre. Multiplier les animations est ce qui fait basculer
    /// une interface du côté « générée ».
    enum Motion {
        static let snap = Animation.spring(response: 0.32, dampingFraction: 0.78)
        static let settle = Animation.spring(response: 0.55, dampingFraction: 0.85)
        static let fixAcquired = Animation.easeOut(duration: 0.9)
    }
}

// MARK: - Matériaux

/// Carte en verre. S'appuie sur le matériau système plutôt que sur une couleur
/// opaque, pour que la carte transparaisse derrière les panneaux du module GPS.
struct GlassCard: ViewModifier {
    var radius: CGFloat = PX.Radius.card
    var emphasis: Bool = false

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(PX.Color.abyss.opacity(emphasis ? 0.72 : 0.55))
            )
            .overlay(
                // Filet supérieur clair : imite la réfraction sur l'arête d'une
                // vitre. C'est ce détail qui sépare « verre » de « rectangle flou ».
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.14), .white.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            )
    }
}

extension View {
    func glassCard(radius: CGFloat = PX.Radius.card, emphasis: Bool = false) -> some View {
        modifier(GlassCard(radius: radius, emphasis: emphasis))
    }

    /// Halo ambré. Réservé à l'état actif du spoof — voir la note en tête.
    func signalGlow(active: Bool) -> some View {
        shadow(color: active ? PX.Color.signal.opacity(0.45) : .clear, radius: 18, y: 4)
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
                    .fill(
                        enabled
                        ? LinearGradient(
                            colors: [tint, tint.opacity(0.78)],
                            startPoint: .top, endPoint: .bottom
                        )
                        : LinearGradient(colors: [PX.Color.strata, PX.Color.strata],
                                         startPoint: .top, endPoint: .bottom)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
                    .strokeBorder(.white.opacity(enabled ? 0.18 : 0.04), lineWidth: 0.8)
            )
            .shadow(color: enabled ? tint.opacity(0.35) : .clear, radius: 16, y: 6)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(PX.Motion.snap, value: configuration.isPressed)
    }
}

/// Champ de saisie. Le libellé flotte au-dessus plutôt qu'en placeholder :
/// un placeholder disparaît à la frappe, et l'utilisateur qui revient sur un
/// formulaire à demi rempli ne sait plus quel champ est lequel.
struct FieldStyle: ViewModifier {
    let label: String
    var mono: Bool = false

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: PX.Space.hair + 2) {
            Text(label.uppercased())
                .font(PX.Font.mono(10, .semibold))
                .tracking(0.9)
                .foregroundStyle(PX.Color.inkFaint)

            content
                .font(mono ? PX.Font.mono(15) : PX.Font.body(16))
                .foregroundStyle(PX.Color.ink)
                .padding(.horizontal, PX.Space.base)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
                        .fill(PX.Color.night.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
                        .strokeBorder(PX.Color.horizon, lineWidth: 1)
                )
        }
    }
}

extension View {
    func field(_ label: String, mono: Bool = false) -> some View {
        modifier(FieldStyle(label: label, mono: mono))
    }
}

// MARK: - Élément signature

/// La bande d'instruments.
///
/// C'est l'élément par lequel l'app doit être reconnue. Présente sur chaque
/// écran, en SF Mono à chiffres tabulaires, elle affiche en permanence ce que
/// l'appareil déclare : position, état de session, cible RSD. Un instrument de
/// bord plutôt qu'un badge de statut.
///
/// Elle existe parce que le sujet de l'app est précisément *ce que l'appareil
/// affirme*. Rendre cette affirmation visible en continu, dans une police qui
/// signale « valeur machine », c'est traduire la thèse du produit en interface
/// plutôt que de la décrire dans un texte d'accueil.
struct InstrumentStrip: View {
    let latitude: Double?
    let longitude: Double?
    let sessionLabel: String
    let live: Bool

    var body: some View {
        HStack(spacing: PX.Space.snug) {
            Circle()
                .fill(live ? PX.Color.signal : PX.Color.inkFaint)
                .frame(width: 7, height: 7)
                .signalGlow(active: live)

            Text(coordinateText)
                .font(PX.Font.mono(13, .semibold))
                .monospacedDigit()
                .foregroundStyle(live ? PX.Color.signal : PX.Color.inkMuted)
                .contentTransition(.numericText())

            Spacer(minLength: PX.Space.tight)

            Text(sessionLabel.uppercased())
                .font(PX.Font.mono(10, .semibold))
                .tracking(0.8)
                .foregroundStyle(PX.Color.inkFaint)
        }
        .padding(.horizontal, PX.Space.base)
        .padding(.vertical, 11)
        .glassCard(radius: PX.Radius.chip)
        .animation(PX.Motion.settle, value: live)
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
