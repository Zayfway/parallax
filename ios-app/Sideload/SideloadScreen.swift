import SwiftUI

/// Onglet Installer.
///
/// Trois changements par rapport à la capture d'origine, chacun pour une raison :
///
/// 1. L'action principale est **ancrée** au-dessus de la barre d'onglets via
///    `safeAreaInset`, et non posée en fin de pile où elle finit dessous.
/// 2. Le bandeau LocalDevVPN nomme l'action (« Ouvrir LocalDevVPN ») plutôt que
///    l'état (« Tunnel désactivé ») : un symptôme ne dit pas quoi faire.
/// 3. Le sélecteur d'app et le canal Stable/Nightly sont deux segments empilés
///    plutôt qu'un menu déroulant qui recouvre le contrôle voisin à l'ouverture.
struct SideloadScreen: View {

    @EnvironmentObject private var connection: DeviceConnection
    @EnvironmentObject private var location: LocationEngine

    @State private var email = ""
    @State private var password = ""
    @State private var target: InstallTarget = .sideStore
    @State private var channel: Channel = .stable
    @State private var installing = false

    enum InstallTarget: String, CaseIterable {
        case sideStore = "SideStore"
        case withLiveContainer = "+ LiveContainer"
    }
    enum Channel: String, CaseIterable { case stable = "Stable", nightly = "Nightly" }

    var body: some View {
        ZStack {
            PX.Color.canvas

            ScrollView {
                VStack(spacing: PX.Space.snug) {
                    InstrumentStrip(
                        latitude: location.currentFix?.latitude,
                        longitude: location.currentFix?.longitude,
                        sessionLabel: connection.tunnelState.shortLabel,
                        live: location.state == .simulating
                    )

                    header

                    accountCard
                    targetCard

                    if !connection.tunnelState.isConnected {
                        tunnelCard
                    }
                }
                .padding(.horizontal, PX.Space.base)
                .padding(.bottom, PX.Space.wide)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await install() }
            } label: {
                Text(installing ? "Installation…" : "Installer \(target.rawValue)")
            }
            .buttonStyle(ProminentButtonStyle(enabled: canInstall))
            .disabled(!canInstall)
            .padding(.horizontal, PX.Space.base)
            .padding(.bottom, PX.Space.tight)
            .background(
                LinearGradient(colors: [PX.Color.night.opacity(0), PX.Color.night],
                               startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .allowsHitTesting(false),
                alignment: .bottom
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Installer")
                .font(PX.Font.display(30, .heavy))
                .foregroundStyle(PX.Color.ink)
            Text("Signé sur cet appareil, avec ton compte.")
                .font(PX.Font.body(13))
                .foregroundStyle(PX.Color.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, PX.Space.tight)
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: PX.Space.snug) {
            SectionLabel("Compte Apple")

            TextField("", text: $email, prompt: Text("nom@icloud.com")
                .foregroundStyle(PX.Color.inkFaint))
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .field("Identifiant", mono: true)

            SecureField("", text: $password, prompt: Text("••••••••")
                .foregroundStyle(PX.Color.inkFaint))
                .textContentType(.password)
                .field("Mot de passe")

            // La revendication de confidentialité est posée là où l'utilisateur
            // décide, pas enterrée dans un écran « À propos ». Et elle est
            // exacte : le relais Anisette est nommé, parce qu'il existe.
            Label {
                Text("Le mot de passe reste sur l'appareil. L'attestation Apple passe par un relais Anisette, configurable dans les réglages.")
            } icon: {
                Image(systemName: "lock.shield")
            }
            .font(PX.Font.body(11.5))
            .foregroundStyle(PX.Color.inkFaint)
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: PX.Space.snug) {
            SectionLabel("Application")
            SegmentedRow(selection: $target, options: InstallTarget.allCases) { $0.rawValue }
            SegmentedRow(selection: $channel, options: Channel.allCases) { $0.rawValue }
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private var tunnelCard: some View {
        HStack(alignment: .top, spacing: PX.Space.snug) {
            Image(systemName: "shield.lefthalf.filled.slash")
                .font(.system(size: 17))
                .foregroundStyle(PX.Color.alert)

            VStack(alignment: .leading, spacing: 3) {
                Text("Ouvre LocalDevVPN")
                    .font(PX.Font.display(14, .semibold))
                    .foregroundStyle(PX.Color.alert)
                Text("L'installation passe par son tunnel local.")
                    .font(PX.Font.body(12))
                    .foregroundStyle(PX.Color.inkMuted)
            }

            Spacer()

            Link(destination: URL(string: "localdevvpn://")!) {
                Text("Ouvrir")
                    .font(PX.Font.display(13, .semibold))
                    .foregroundStyle(PX.Color.alert)
                    .padding(.horizontal, PX.Space.snug)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(PX.Color.alert.opacity(0.16)))
            }
        }
        .padding(PX.Space.base)
        .background(
            RoundedRectangle(cornerRadius: PX.Radius.card, style: .continuous)
                .fill(PX.Color.alert.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PX.Radius.card, style: .continuous)
                .strokeBorder(PX.Color.alert.opacity(0.28), lineWidth: 1)
        )
    }

    private var canInstall: Bool {
        !email.isEmpty && !password.isEmpty
            && connection.tunnelState.isConnected && !installing
    }

    private func install() async {
        installing = true
        defer { installing = false }
        // → Engine.runOneClick() : jumelage → connexion → login → signature → install
    }
}

// MARK: - Composants partagés
/// Segment maison plutôt que `Picker(.segmented)` : le contrôle système ne
/// laisse pas assez de prise sur le rayon ni sur la police, et le résultat
/// jurerait avec le reste. Le comportement, lui, reste identique.
struct SegmentedRow<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let title: (T) -> String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                let active = option == selection
                Text(title(option))
                    .font(PX.Font.display(13, active ? .semibold : .medium))
                    .foregroundStyle(active ? PX.Color.ink : PX.Color.inkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: PX.Radius.chip, style: .continuous)
                            .fill(active ? PX.Color.strata : .clear)
                            .shadow(color: active ? .black.opacity(0.35) : .clear, radius: 6, y: 2)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(PX.Motion.snap) { selection = option }
                    }
            }
        }
        .padding(3)
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
