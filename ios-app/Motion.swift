import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
// MOTION — le moment orchestré et ce qui gravite autour
//
// Principe de retenue : **une** animation mémorable, tout le reste discret.
// Multiplier les effets est précisément ce qui fait basculer une interface du
// côté « générée ». Ici le moment, c'est l'acquisition d'un point — quand le
// GPS bascule dans le mensonge. Le reste se contente de ne pas sauter.
// ═══════════════════════════════════════════════════════════════════════════

/// Anneaux qui se propagent une fois depuis le marqueur, à la validation d'une
/// téléportation.
///
/// Se déclenche sur `trigger`, pas en boucle : un effet permanent devient du
/// décor et cesse de signifier quoi que ce soit. Celui-ci dit « le fix est
/// pris », une fois, et disparaît.
struct FixAcquiredRing: View {
    let trigger: Int

    @State private var wave: CGFloat = 0
    @State private var visible = false

    var body: some View {
        ZStack {
            ring(delay: 0)
            ring(delay: 0.14)
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            wave = 0
            visible = true
            withAnimation(.easeOut(duration: 1.1)) { wave = 1 }
            withAnimation(.easeOut(duration: 1.1).delay(0.1)) { visible = false }
        }
    }

    private func ring(delay: Double) -> some View {
        Circle()
            .strokeBorder(PX.Color.signal.opacity(visible ? 0.85 : 0), lineWidth: 2)
            .frame(width: 18 + wave * 130, height: 18 + wave * 130)
    }
}

/// Marqueur de position simulée.
///
/// Halo qui respire quand la session est vivante, gris et immobile sinon. La
/// différence doit être lisible du coin de l'œil, sans lire de texte.
struct SimulatedMarker: View {
    let live: Bool
    let degraded: Bool

    @State private var pulse = false

    var body: some View {
        ZStack {
            if live {
                Circle()
                    .fill(PX.Color.signal.opacity(0.18))
                    .frame(width: pulse ? 46 : 30, height: pulse ? 46 : 30)
                    .blur(radius: 6)
            }

            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                .signalGlow(live, radius: 14)
        }
        .animation(PX.Motion.settle, value: live)
        .onAppear { withAnimation(PX.Motion.breathe) { pulse = true } }
    }

    private var color: Color {
        if degraded { return PX.Color.alert }
        return live ? PX.Color.signal : PX.Color.inkFaint
    }
}

/// Palet analogique. Le cap vient de l'angle, la vitesse de l'amplitude.
///
/// Trois vitesses discrètes plutôt qu'un continu : à un fix par seconde, un
/// continu produit des écarts que le système lisse de toute façon, et le
/// retour discret est bien plus contrôlable au pouce. Chaque changement de
/// palier donne un retour haptique — on sent qu'on a changé de vitesse sans
/// quitter la carte des yeux.
struct Joystick: View {

    let onMove: (_ bearing: Double, _ metersPerSecond: Double) -> Void

    @State private var offset: CGSize = .zero
    @State private var ticker: Timer?
    @State private var tier: Int = 0
    @State private var active = false

    private let radius: CGFloat = 52
    private let deadzone: CGFloat = 8

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .background(Circle().fill(PX.Color.abyss.opacity(0.5)))
                .overlay(
                    Circle().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.03)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.9
                    )
                )

            // Repère de cap : n'apparaît que pendant le geste.
            Circle()
                .trim(from: 0, to: 0.08)
                .stroke(PX.Color.azimuth.opacity(active ? 0.9 : 0), lineWidth: 3)
                .frame(width: radius * 1.75, height: radius * 1.75)
                .rotationEffect(.degrees(bearing - 90 - 14.4))

            Circle()
                .fill(LinearGradient(colors: [PX.Color.azimuth, PX.Color.azimuth.opacity(0.8)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.8))
                .offset(offset)
                .shadow(color: PX.Color.azimuth.opacity(0.45), radius: 12, y: 4)
        }
        .frame(width: radius * 2, height: radius * 2)
        .scaleEffect(active ? 1.04 : 1)
        .animation(PX.Motion.tap, value: active)
        .sensoryFeedback(.selection, trigger: tier)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let raw = value.translation
                    let magnitude = min(hypot(raw.width, raw.height), radius)
                    let angle = atan2(raw.width, -raw.height)
                    offset = CGSize(width: sin(angle) * magnitude,
                                    height: -cos(angle) * magnitude)
                    active = true
                    updateTier(magnitude)
                    startTicking()
                }
                .onEnded { _ in
                    withAnimation(PX.Motion.tap) { offset = .zero }
                    active = false
                    tier = 0
                    ticker?.invalidate()
                    ticker = nil
                }
        )
        .accessibilityLabel("Joystick de déplacement")
    }

    private var bearing: Double {
        var b = atan2(offset.width, -offset.height) * 180 / .pi
        if b < 0 { b += 360 }
        return b
    }

    private func updateTier(_ magnitude: CGFloat) {
        let next: Int = switch magnitude / radius {
        case ..<0.4: 1     // marche
        case ..<0.75: 2    // course
        default: 3         // véhicule
        }
        if next != tier { tier = next }
    }

    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let magnitude = hypot(offset.width, offset.height)
            guard magnitude > deadzone else { return }
            let speed: Double = switch tier {
            case 1: 1.4
            case 2: 4.5
            default: 13.0
            }
            onMove(bearing, speed)
        }
    }
}

/// Barre d'état.
///
/// Un état dégradé se dit franchement : pendant la reprise, la vraie position
/// est visible des autres apps. Masquer ça derrière un spinner neutre ferait
/// prendre à l'utilisateur des décisions qu'il regretterait.
struct StatusBar: View {
    let state: LocationEngine.State

    var body: some View {
        HStack(spacing: PX.Space.tight) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .signalGlow(state == .simulating, radius: 8)

            Text(message)
                .font(PX.Font.body(13))
                .foregroundStyle(PX.Color.inkMuted)
                .contentTransition(.opacity)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, PX.Space.base)
        .padding(.vertical, 11)
        .glassCard(radius: PX.Radius.chip)
        .animation(PX.Motion.settle, value: message)
    }

    private var color: Color {
        switch state {
        case .simulating: PX.Color.signal
        case .degraded, .waitingForWiFi: PX.Color.alert
        case .failed: PX.Color.alert
        default: PX.Color.inkFaint
        }
    }

    private var message: String {
        switch state {
        case .idle: "Touche la carte pour choisir un point."
        case .mountingDDI: "Montage de l'image développeur…"
        case .connecting: "Ouverture du canal…"
        case .simulating: "Position simulée active."
        case .degraded(let n): "Canal perdu — position réelle visible. Reprise (\(n))…"
        case .waitingForWiFi: "Position réelle visible. Repasse en Wi-Fi."
        case .failed(let why): why
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// LES MOMENTS
//
// Trois instants méritent d'être marqués, et trois seulement : le compte qui
// s'ouvre, l'app qui se pose, la position qui bascule. Le reste se contente de
// ne pas sauter — c'est la règle de retenue en tête de fichier, et multiplier
// les effets est exactement ce qui fait basculer une interface du côté
// « générée ».
// ═══════════════════════════════════════════════════════════════════════════

/// Sceau qui se dessine, puis se pose.
///
/// Utilisé pour un aboutissement — compte connecté, app installée. Le trait
/// se referme avant que le disque n'apparaisse : on voit la chose *se faire*,
/// ce qui la rend crédible, là où une coche qui surgit ne raconte rien.
struct SealMoment: View {
    let tint: Color
    let icon: String
    /// Change de valeur pour rejouer. Un `Bool` ne permettrait pas de rejouer
    /// deux fois de suite le même aboutissement.
    let trigger: Int

    @State private var sweep: CGFloat = 0
    @State private var pop: CGFloat = 0.7
    @State private var glow: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(glow * 0.16))
                .frame(width: 58, height: 58)
                .blur(radius: 12)

            Circle()
                .trim(from: 0, to: sweep)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 44, height: 44)
                .rotationEffect(.degrees(-90))

            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(tint)
                .scaleEffect(pop)
                .opacity(Double(pop > 0.9 ? 1 : 0))
        }
        .onChange(of: trigger) { _, _ in play() }
        .onAppear { play() }
    }

    private func play() {
        sweep = 0; pop = 0.7; glow = 0
        withAnimation(.easeOut(duration: 0.42)) { sweep = 1 }
        withAnimation(PX.Motion.acquire.delay(0.30)) { pop = 1 }
        withAnimation(PX.Motion.settle.delay(0.30)) { glow = 1 }
    }
}

/// Onde unique qui traverse une carte, de gauche à droite.
///
/// Marque une transition franchie sans rien ajouter à l'écran : la lueur passe
/// et disparaît. À réserver aux aboutissements, sous peine de devenir du décor.
struct SweepHighlight: ViewModifier {
    let tint: Color
    let trigger: Int

    @State private var position: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [.clear, tint.opacity(0.22), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 0.55)
                    .offset(x: position * geometry.size.width * 1.6)
                    .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: PX.Radius.card, style: .continuous))
            )
            .onChange(of: trigger) { _, _ in
                position = -1
                withAnimation(.easeInOut(duration: 0.85)) { position = 1 }
            }
    }
}

extension View {
    /// Une onde traverse la vue quand `trigger` change.
    func sweep(_ tint: Color, trigger: Int) -> some View {
        modifier(SweepHighlight(tint: tint, trigger: trigger))
    }
}
