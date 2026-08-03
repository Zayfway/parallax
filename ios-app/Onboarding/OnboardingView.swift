import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
// PREMIER LANCEMENT
//
// Parallax a trois préalables non évidents — un VPN loopback, un jumelage,
// (parfois) un compte Apple — et rien ne les installe à ta place. Sans ce
// guide, on ouvre l'app, on touche « Installer », et rien ne se connecte, sans
// savoir pourquoi. Quatre écrans, une fois, pour poser le décor. « Passer »
// reste toujours disponible : c'est un guide, pas un péage.
// ═══════════════════════════════════════════════════════════════════════════

struct OnboardingView: View {
    let finish: () -> Void

    @State private var page = 0
    @State private var shown = false

    private struct Slide: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let title: String
        let body: String
    }

    private let slides: [Slide] = [
        Slide(icon: "point.3.filled.connected.trianglepath.dotted",
              tint: PX.Color.azimuth,
              title: "Bienvenue dans Parallax",
              body: "Installer des apps hors App Store et simuler ta position GPS — tout sur l'iPhone, sans Mac, sans PC, sans câble."),
        Slide(icon: "network",
              tint: PX.Color.azimuth,
              title: "1 · Un VPN loopback",
              body: "Installe LocalDevVPN ou StosVPN et touche Connect. C'est lui qui ouvre l'adresse locale (10.7.0.1) par laquelle Parallax parle à l'appareil. Sans lui, rien ne se connecte."),
        Slide(icon: "lock.iphone",
              tint: PX.Color.azimuth,
              title: "2 · Le jumelage",
              body: "Dans Réglages › Confidentialité et sécurité › Mode développeur, touche « Jumeler avec Parallax » et recopie les six chiffres. Une seule fois."),
        Slide(icon: "location.viewfinder",
              tint: PX.Color.verdant,
              title: "3 · Installe, ou simule",
              body: "Un compte Apple gratuit signe et installe tes apps. Le GPS, lui, n'en a pas besoin : le jumelage et le VPN suffisent. À toi de jouer."),
    ]

    var body: some View {
        ZStack {
            PX.Color.canvas

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Passer") { finish() }
                        .font(PX.Font.display(14, .semibold))
                        .foregroundStyle(PX.Color.inkMuted)
                }
                .padding(.horizontal, PX.Space.base)
                .padding(.top, PX.Space.tight)

                TabView(selection: $page) {
                    ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                        slideView(slide).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(PX.Motion.settle, value: page)

                dots

                Button {
                    if page < slides.count - 1 {
                        withAnimation(PX.Motion.settle) { page += 1 }
                    } else {
                        finish()
                    }
                } label: {
                    Text(page < slides.count - 1 ? "Suivant" : "Commencer")
                }
                .buttonStyle(ProminentButtonStyle(tint: page == slides.count - 1 ? PX.Color.verdant : PX.Color.azimuth))
                .padding(.horizontal, PX.Space.loose)
                .padding(.bottom, PX.Space.loose)
            }
        }
        .onAppear { shown = true }
    }

    private func slideView(_ slide: Slide) -> some View {
        VStack(spacing: PX.Space.loose) {
            Spacer()
            Image(systemName: slide.icon)
                .font(.system(size: 66, weight: .light))
                .foregroundStyle(slide.tint)
                .frame(width: 140, height: 140)
                .background(
                    Circle().fill(
                        RadialGradient(colors: [slide.tint.opacity(0.22), slide.tint.opacity(0.04)],
                                       center: .center, startRadius: 4, endRadius: 90)))
                .overlay(Circle().strokeBorder(slide.tint.opacity(0.28), lineWidth: 1))
                .shadow(color: slide.tint.opacity(0.35), radius: 30, y: 10)

            VStack(spacing: PX.Space.snug) {
                Text(slide.title)
                    .font(PX.Font.display(26, .heavy))
                    .tracking(-0.3)
                    .foregroundStyle(PX.Color.ink)
                    .multilineTextAlignment(.center)
                Text(slide.body)
                    .font(PX.Font.body(15))
                    .foregroundStyle(PX.Color.inkMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, PX.Space.loose)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(0..<slides.count, id: \.self) { i in
                Capsule()
                    .fill(i == page ? PX.Color.azimuth : PX.Color.horizon)
                    .frame(width: i == page ? 22 : 7, height: 7)
                    .animation(PX.Motion.settle, value: page)
            }
        }
        .padding(.bottom, PX.Space.base)
    }
}
