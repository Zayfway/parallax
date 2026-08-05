// Prism — système de design. Copie namespacée de celui de Parallax (PX -> PR),
// mêmes tokens, mêmes couches de verre. Référence unique de tout le style.
//
// DEUX RÈGLES ABSOLUES
//
// 1. L'ambre `PR.Color.signal` signifie « MODIFICATION ACTIVE EN MÉMOIRE », et
//    rien d'autre. Une valeur écrite/figée dans la RAM de la cible. Jamais
//    décoratif. Quand l'écran devient chaud, c'est qu'on ment à la cible. Pour
//    le reste : azimuth = scan/affinage en cours, verdant = candidat verrouillé
//    / écrit, alert = échec. `signalGlow` est le seul halo ambré, gaté sur une
//    écriture active.
//
// 2. Mono = valeur machine (adresses, i32, protections, tags). Rounded =
//    adressé à l'humain. Si c'est en mono, ça vient de la mémoire de l'appareil.

import SwiftUI

enum PR {
    enum Color {
        static let night = SwiftUI.Color(hex: 0x0A0D18) // canvas (pas noir pur)
        static let abyss = SwiftUI.Color(hex: 0x131829) // tint de carte par défaut
        static let strata = SwiftUI.Color(hex: 0x1C2338) // surface (bouton désactivé)
        static let horizon = SwiftUI.Color(hex: 0x2A3352) // bordures / séparateurs
        static let azimuth = SwiftUI.Color(hex: 0x7C8CFF) // interactif primaire (pervenche)
        static let signal = SwiftUI.Color(hex: 0xF5A65B) // ★ AMBRE — modification active, rien d'autre
        static let verdant = SwiftUI.Color(hex: 0x4ADE9B) // succès / verrouillé
        static let alert = SwiftUI.Color(hex: 0xFF6B6B) // échec
        static let ink = SwiftUI.Color(hex: 0xF2F4FF) // texte principal
        static let inkMuted = SwiftUI.Color(hex: 0x9AA3C4) // texte secondaire
        static let inkFaint = SwiftUI.Color(hex: 0x5A6488) // texte tertiaire / inactif

        // Fond de chaque écran : donne au verre quelque chose à réfracter.
        static var canvas: some View {
            ZStack {
                night
                RadialGradient(
                    colors: [SwiftUI.Color(hex: 0x252E5A).opacity(0.9), SwiftUI.Color(hex: 0x171D38).opacity(0)],
                    center: .top, startRadius: 0, endRadius: 540)
                RadialGradient(
                    colors: [azimuth.opacity(0.13), .clear],
                    center: .bottom, startRadius: 0, endRadius: 460)
                LinearGradient(
                    colors: [SwiftUI.Color.white.opacity(0.02), .clear, SwiftUI.Color.black.opacity(0.18)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .ignoresSafeArea()
        }
    }

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
}

// ── Verre + halos + cascade ─────────────────────────────────────────────────

struct GlassCard: ViewModifier {
    var radius: CGFloat = PR.Radius.card
    var tint: Color = PR.Color.abyss
    var emphasis: Bool = false
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let hi = emphasis ? 0.82 : 0.60
        let lo = emphasis ? 0.66 : 0.44
        return content
            .background(.ultraThinMaterial, in: shape)
            .background(
                LinearGradient(colors: [tint.opacity(hi), tint.opacity(lo)],
                               startPoint: .top, endPoint: .bottom), in: shape)
            .overlay(
                LinearGradient(colors: [.white.opacity(0.08), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .clipShape(shape))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.06), .white.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1))
            .shadow(color: .black.opacity(0.44), radius: 24, y: 12)
    }
}

extension View {
    func glassCard(radius: CGFloat = PR.Radius.card, tint: Color = PR.Color.abyss, emphasis: Bool = false) -> some View {
        modifier(GlassCard(radius: radius, tint: tint, emphasis: emphasis))
    }
    /// Le seul halo ambré — réservé à une écriture active.
    func signalGlow(_ active: Bool, radius: CGFloat = 16) -> some View {
        shadow(color: active ? PR.Color.signal.opacity(0.55) : .clear, radius: active ? radius : 0)
    }
    /// Entrée en cascade : opacité + décalage, animés par `stagger(index)`.
    func appear(_ index: Int, _ shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
            .animation(PR.Motion.stagger(index), value: shown)
    }
}

// ── Boutons ─────────────────────────────────────────────────────────────────

struct ProminentButtonStyle: ButtonStyle {
    var tint: Color = PR.Color.azimuth
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PR.Font.display(17, .semibold))
            .foregroundStyle(PR.Color.night)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                Capsule().fill(
                    LinearGradient(colors: enabled ? [tint, tint.opacity(0.82)] : [PR.Color.strata, PR.Color.strata],
                                   startPoint: .top, endPoint: .bottom)))
            .opacity(enabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.972 : 1)
            .animation(PR.Motion.tap, value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = PR.Color.ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PR.Font.display(16, .semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Capsule().fill(PR.Color.strata.opacity(0.6)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
            .scaleEffect(configuration.isPressed ? 0.972 : 1)
            .animation(PR.Motion.tap, value: configuration.isPressed)
    }
}

// ── Champ de saisie ─────────────────────────────────────────────────────────

struct FieldStyle: ViewModifier {
    let label: String
    var mono: Bool = false
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: PR.Radius.control, style: .continuous)
        return VStack(alignment: .leading, spacing: PR.Space.hair) {
            Text(label)
                .font(PR.Font.display(12, .semibold))
                .foregroundStyle(focused ? PR.Color.azimuth : PR.Color.inkMuted)
            content
                .font(mono ? PR.Font.mono(15) : PR.Font.body(16))
                .foregroundStyle(PR.Color.ink)
                .focused($focused)
                .padding(.horizontal, PR.Space.snug)
                .padding(.vertical, PR.Space.tight + 2)
                .background(shape.fill(PR.Color.night.opacity(0.55)))
                .overlay(shape.strokeBorder(
                    focused ? PR.Color.azimuth.opacity(0.6) : PR.Color.horizon,
                    lineWidth: focused ? 1.5 : 1))
        }
        .animation(PR.Motion.tap, value: focused)
    }
}

extension View {
    func field(_ label: String, mono: Bool = false) -> some View {
        modifier(FieldStyle(label: label, mono: mono))
    }
}

// ── InstrumentStrip — l'élément signature, adapté mémoire (adresse + valeur) ──

struct InstrumentStrip: View {
    var address: UInt64?
    var value: Int32?
    var sessionLabel: String
    var live: Bool = false

    // La pastille exclut TOUJOURS l'ambre (règle 1) : l'ambre déborde ailleurs.
    private var statusTint: Color {
        let l = sessionLabel.lowercased()
        if l.contains("échec") || l.contains("refus") { return PR.Color.alert }
        if l.contains("verrou") || l.contains("écrit") { return PR.Color.verdant }
        if live { return PR.Color.azimuth }
        return PR.Color.inkFaint
    }
    private var addressText: String {
        address.map { String(format: "0x%010llX", $0) } ?? "0x——————————"
    }
    private var valueText: String { value.map { String($0) } ?? "————" }

    var body: some View {
        HStack(spacing: PR.Space.snug) {
            Circle().fill(statusTint).frame(width: 8, height: 8)
                .scaleEffect(live ? 1 : 0.85)
                .animation(live ? PR.Motion.breathe : PR.Motion.settle, value: live)
            VStack(alignment: .leading, spacing: 2) {
                Text(addressText)
                    .font(PR.Font.mono(13, .semibold)).monospacedDigit()
                    .foregroundStyle(PR.Color.ink)
                    .contentTransition(.numericText())
                Text(sessionLabel)
                    .font(PR.Font.body(12)).foregroundStyle(PR.Color.inkMuted)
            }
            Spacer()
            Text(valueText)
                .font(PR.Font.mono(15, .bold)).monospacedDigit()
                .foregroundStyle(statusTint)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, PR.Space.base)
        .padding(.vertical, PR.Space.snug)
        .glassCard(radius: PR.Radius.chip)
    }
}

// ── Composants annexes ──────────────────────────────────────────────────────

struct ScreenHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: () -> Accessory
    init(_ title: String, _ subtitle: String,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(PR.Font.display(33, .heavy)).tracking(-0.4)
                    .foregroundStyle(PR.Color.ink)
                Text(subtitle).font(PR.Font.body(15)).foregroundStyle(PR.Color.inkMuted)
            }
            Spacer()
            accessory()
        }
        .padding(.top, PR.Space.tight)
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(PR.Font.display(12, .bold)).tracking(0.6)
            .foregroundStyle(PR.Color.inkFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Tag: View {
    let icon: String
    let text: String
    var tint: Color = PR.Color.azimuth
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(text).font(PR.Font.body(12, .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, PR.Space.tight).padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.14)))
    }
}

extension SwiftUI.Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
