import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
// ONGLET INSTALLER
//
// La fonctionnalité principale : mettre SideStore, ou SideStore + LiveContainer,
// sur l'appareil sans ordinateur. Trois préalables doivent tenir en même temps
// — compte Apple, identité de l'appareil, lien RSD — et c'est précisément là
// que l'utilisateur se perd s'il doit deviner lequel manque.
//
// L'écran est donc bâti sur le modèle de PairingScreen, qui a résolu le même
// problème :
//
//   · une machine à phases explicite, pas des booléens éparpillés
//   · UN seul élément coloré — le bandeau — qui porte l'état
//   · un rail d'étapes numérotées qui dit « tu es ici » sans une ligne de texte
//   · des entrées en cascade
//
//   gris      · un préalable manque
//   pervenche · prêt, ou opération en cours
//   vert      · installé
//   rouge     · échec
//
// L'ambre n'apparaît jamais ici : elle signifie « position simulée active »,
// et une couleur signature qui déborde cesse d'être un signal.
//
// La carte de compte est celle de l'écran Certificats. Il n'y a qu'une session
// Apple dans l'app, donc une seule interface pour l'ouvrir — l'écran avait ses
// propres champs de mot de passe, qui ne servaient plus à rien.
// ═══════════════════════════════════════════════════════════════════════════

struct SideloadScreen: View {

    @EnvironmentObject private var connection: DeviceConnection
    @EnvironmentObject private var location: LocationEngine
    @EnvironmentObject private var account: AppleAccountModel

    @State private var target: InstallTarget = .sideStore
    @State private var channel: Channel = .stable
    @State private var installing = false
    @State private var shown = false
    @State private var progress: InstallProgress?
    @State private var failure: String?
    @State private var installed: String?
    /// Incrémenté à chaque aboutissement, pour rejouer le sceau.
    @State private var doneCount = 0
    /// Permet de corriger une adresse devenue fausse sans reconstruire l'app.
    @AppStorage("ipaSourceOverride") private var sourceOverride: String = ""

    enum InstallTarget: String, CaseIterable {
        case sideStore = "SideStore"
        case withLiveContainer = "+ LiveContainer"

        /// Les variantes correspondent aux `SpecialApp` qu'isideload sait
        /// reconnaître : `SideStore` et `SideStoreLc`. C'est Rust qui confirmera
        /// laquelle il a réellement détectée dans l'IPA signé.
        func url(for channel: Channel) -> String {
            switch (self, channel) {
            case (.sideStore, .stable):
                "https://github.com/SideStore/SideStore/releases/latest/download/SideStore.ipa"
            case (.sideStore, .nightly):
                "https://github.com/SideStore/SideStore/releases/download/nightly/SideStore.ipa"
            case (.withLiveContainer, .stable):
                "https://github.com/SideStore/SideStore/releases/latest/download/SideStore-LiveContainer.ipa"
            case (.withLiveContainer, .nightly):
                "https://github.com/SideStore/SideStore/releases/download/nightly/SideStore-LiveContainer.ipa"
            }
        }
    }
    enum Channel: String, CaseIterable { case stable = "Stable", nightly = "Nightly" }

    // MARK: - Phase

    /// Même principe que `PairingScreen` : une machine explicite, et un seul
    /// élément coloré qui porte l'état. Les préalables sont ordonnés comme
    /// l'utilisateur les remplit, pour que le rail puisse dire « tu es ici ».
    enum Phase: Equatable {
        case needsAccount
        case needsPairing
        case needsLink
        case ready
        case working(Int, String)
        case done(String)
        case failed(String)

        var step: Int {
            switch self {
            case .needsAccount:              0
            case .needsPairing, .needsLink:  1
            case .ready:                     2
            case .working, .done:            3
            case .failed:                    0
            }
        }

        var tint: Color {
            switch self {
            case .needsAccount, .needsPairing, .needsLink: PX.Color.inkFaint
            case .ready:                                   PX.Color.azimuth
            case .working:                                 PX.Color.azimuth
            case .done:                                    PX.Color.verdant
            case .failed:                                  PX.Color.alert
            }
        }

        var label: String {
            switch self {
            case .needsAccount: "Compte requis"
            case .needsPairing: "Jumelage requis"
            case .needsLink:    "Lien requis"
            case .ready:        "Prêt"
            case .working:      "Installation"
            case .done:         "Installé"
            case .failed:       "Échec"
            }
        }

        var icon: String {
            switch self {
            case .needsAccount: "person.crop.circle.badge.exclamationmark"
            case .needsPairing: "lock.iphone"
            case .needsLink:    "link.badge.plus"
            case .ready:        "checkmark.circle"
            case .working:      "arrow.down.circle"
            case .done:         "checkmark.seal.fill"
            case .failed:       "exclamationmark.triangle.fill"
            }
        }

        var detail: String {
            switch self {
            case .needsAccount: "connecte-toi ci-dessous"
            case .needsPairing: "aucune identité d'appareil — passe par Jumelage"
            case .needsLink:    "établis le lien dans l'onglet Jumelage"
            case .ready:        "tout est en place"
            case .working(_, let what): what.lowercased()
            case .done(let name): "\(name) est sur ton écran d'accueil"
            case .failed:       "voir le détail ci-dessous"
            }
        }
    }

    private var phase: Phase {
        if let failure { return .failed(failure) }
        if let installed { return .done(installed) }
        if let progress, installing { return .working(progress.percent, progress.label) }
        if !account.isConnected { return .needsAccount }
        if FFI.pairedDevice(besidePairingFile: PairingStore.fileURL) == nil { return .needsPairing }
        if connection.tunnelPointer == nil { return .needsLink }
        return .ready
    }

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
                        .appear(0, shown)

                    statusBanner
                        .appear(1, shown)
                        .sweep(PX.Color.verdant, trigger: doneCount)

                    rail
                        .appear(2, shown)

                    // La carte de compte est celle de l'écran Certificats :
                    // une seule session Apple dans toute l'app, donc une seule
                    // interface pour l'ouvrir.
                    AppleAccountCard()
                        .appear(3, shown)

                    targetCard
                        .appear(4, shown)

                    if installing || progress != nil {
                        progressCard
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.96).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }

                    if let failure {
                        failureCard(failure)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, PX.Space.base)
                .padding(.bottom, PX.Space.wide)
            }
        }
        .onAppear { shown = true }
        .animation(PX.Motion.settle, value: installing)
        .animation(PX.Motion.acquire, value: installed)
        .animation(PX.Motion.settle, value: failure)
        .onReceive(NotificationCenter.default.publisher(for: .installProgress)) { note in
            guard let update = note.object as? InstallProgress else { return }
            withAnimation(PX.Motion.settle) { progress = update }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await install() }
            } label: {
                Text(actionLabel)
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

    /// Le seul élément qui change de couleur. Il porte l'état à lui seul, ce
    /// qui évite de teinter six composants et de les tenir synchronisés.
    private var statusBanner: some View {
        HStack(spacing: PX.Space.snug) {
            ZStack {
                if case .done = phase {
                    SealMoment(tint: PX.Color.verdant,
                               icon: "checkmark.seal.fill",
                               trigger: doneCount)
                } else {
                    Circle()
                        .fill(phase.tint.opacity(0.16))
                        .frame(width: 42, height: 42)
                    Image(systemName: phase.icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(phase.tint)
                }
            }
            .frame(width: 58, height: 58)
            .sensoryFeedback(.success, trigger: doneCount)

            VStack(alignment: .leading, spacing: 2) {
                Text(phase.label)
                    .font(PX.Font.display(15, .semibold))
                    .foregroundStyle(PX.Color.ink)
                Text(phase.detail)
                    .font(PX.Font.body(12))
                    .foregroundStyle(PX.Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(PX.Space.base)
        .glassCard(emphasis: true)
        .overlay(
            RoundedRectangle(cornerRadius: PX.Radius.card, style: .continuous)
                .strokeBorder(phase.tint.opacity(0.34), lineWidth: 1)
        )
        .shadow(color: phase.tint.opacity(0.22), radius: 16, y: 6)
        .animation(PX.Motion.settle, value: phase)
    }

    /// Trois préalables, dans l'ordre où on les remplit. Le trait se remplit
    /// vers le bas : c'est le seul endroit où la progression est un mouvement.
    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Préalables")
                .padding(.bottom, PX.Space.snug)

            step(1, "Compte Apple",
                 "Il signe l'application et enregistre l'appareil auprès d'Apple.")
            connector(filled: phase.step >= 2)
            step(2, "Lien avec l'appareil",
                 "Ouvre LocalDevVPN, puis établis le lien dans l'onglet Jumelage. Le tunnel passe par le VPN loopback, pas par le Wi-Fi.")
            connector(filled: phase.step >= 3)
            step(3, "Installation",
                 "Téléchargement, signature, transfert, puis pose sur l'écran d'accueil.")
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private func step(_ number: Int, _ heading: String, _ detail: String) -> some View {
        let active = phase.step == number
        let done = phase.step > number

        return HStack(alignment: .top, spacing: PX.Space.snug) {
            ZStack {
                Circle()
                    .fill(done ? PX.Color.verdant.opacity(0.18)
                               : active ? PX.Color.azimuth.opacity(0.20)
                                        : Color.white.opacity(0.04))
                    .frame(width: 28, height: 28)

                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(PX.Color.verdant)
                } else {
                    Text("\(number)")
                        .font(PX.Font.mono(12, .bold))
                        .foregroundStyle(active ? PX.Color.azimuth : PX.Color.inkFaint)
                }
            }
            .overlay(
                Circle()
                    .strokeBorder(active ? PX.Color.azimuth.opacity(0.55) : .clear, lineWidth: 1.2)
                    .frame(width: 28, height: 28)
            )
            .scaleEffect(active ? 1.06 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(heading)
                    .font(PX.Font.display(13.5, .semibold))
                    .foregroundStyle(active || done ? PX.Color.ink : PX.Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(PX.Font.body(12))
                    .foregroundStyle(active ? PX.Color.inkMuted : PX.Color.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .animation(PX.Motion.settle, value: phase.step)
    }

    private func connector(filled: Bool) -> some View {
        Rectangle()
            .fill(filled ? PX.Color.verdant.opacity(0.6) : PX.Color.horizon)
            .frame(width: 1.5, height: 22)
            .padding(.leading, 13)
            .animation(PX.Motion.settle, value: filled)
    }

    /// Une seule barre, pervenche : opération en cours. Jamais d'ambre, qui ne
    /// signifie que « position simulée active ».
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: PX.Space.tight) {
            HStack {
                SectionLabel("Installation")
                Spacer()
                Text("\(progress?.percent ?? 0) %")
                    .font(PX.Font.mono(11, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(PX.Color.azimuth)
                    .contentTransition(.numericText())
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(PX.Color.night.opacity(0.55))
                    Capsule()
                        .fill(PX.Color.azimuth)
                        .frame(width: geometry.size.width * CGFloat(progress?.percent ?? 0) / 100)
                }
            }
            .frame(height: 4)

            Text(progress?.label ?? "Préparation")
                .font(PX.Font.body(12))
                .foregroundStyle(PX.Color.inkMuted)
        }
        .padding(PX.Space.base)
        .glassCard()
        .animation(PX.Motion.settle, value: progress)
    }

    private func failureCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: PX.Space.snug) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PX.Color.alert)
            Text(message)
                .font(PX.Font.body(12.5))
                .foregroundStyle(PX.Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(PX.Space.base)
        .glassCard()
        .overlay(
            RoundedRectangle(cornerRadius: PX.Radius.card, style: .continuous)
                .strokeBorder(PX.Color.alert.opacity(0.28), lineWidth: 1)
        )
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

    private var actionLabel: String {
        switch phase {
        case .working(let percent, _): "Installation… \(percent) %"
        case .done:                    "Réinstaller \(target.rawValue)"
        case .needsAccount:            "Connecte ton compte Apple"
        case .needsPairing:            "Jumelage requis"
        case .needsLink:               "Établis le lien"
        default:                       "Installer \(target.rawValue)"
        }
    }

    /// Les trois conditions réelles, dans l'ordre où l'utilisateur les remplit :
    /// compte connecté, lien établi, identité de l'appareil connue. Les champs
    /// de mot de passe locaux ne conditionnent plus rien — la session vient du
    /// modèle partagé.
    private var canInstall: Bool {
        account.isConnected && connection.tunnelPointer != nil && !installing
    }

    /// Enchaîne le tout : le lien doit être vivant, le compte connecté, et
    /// l'identité de l'appareil connue — sans UDID, Apple refuse le profil de
    /// provisionnement avec l'erreur 8220.
    private func install() async {
        guard !installing else { return }

        guard let device = FFI.pairedDevice(besidePairingFile: PairingStore.fileURL) else {
            failure = "Identité de l'appareil inconnue. Refais le jumelage : l'UDID y est relevé une seule fois."
            return
        }

        installing = true
        progress = InstallProgress(percent: 0, label: "Préparation")
        failure = nil
        defer { installing = false }

        do {
            // Le lien d'abord : sans lui, ni transfert ni installation.
            try await connection.connect()
            guard let tunnel = connection.tunnelPointer else {
                failure = "Lien indisponible. Passe par l'onglet Jumelage."
                return
            }
            guard let session = account.sessionPointer else {
                failure = "Connecte-toi à ton compte Apple avant d'installer."
                return
            }

            let ipa = try await download(target: target, channel: channel)
            let special = try await onBackground {
                try FFI.installIPA(
                    session: session, tunnel: tunnel,
                    ipaPath: ipa.path, device: device
                )
            }
            installed = special.isEmpty ? target.rawValue : special
            doneCount += 1
            LogBridge.shared.note("installation terminée : \(installed ?? "")")
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Récupère l'IPA à installer.
    ///
    /// ⚠️ Ces adresses sont les URL publiques usuelles des projets concernés ;
    /// je ne les ai pas vérifiées contre un téléchargement réel. Si l'une
    /// change, elle est surchargeable dans les Réglages plutôt que de figer une
    /// valeur fausse dans le binaire.
    private func download(target: InstallTarget, channel: Channel) async throws -> URL {
        let source = sourceOverride.isEmpty ? target.url(for: channel) : sourceOverride
        guard let url = URL(string: source) else {
            throw InstallError.badSource(source)
        }

        progress = InstallProgress(percent: 0, label: "Téléchargement de \(target.rawValue)")
        let (temporary, response) = try await URLSession.shared.download(from: url)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.download(http.statusCode, source)
        }

        // URLSession supprime son fichier temporaire à la sortie du scope ;
        // on le déplace sous un nom stable avant de le confier à Rust.
        let destination = URL.temporaryDirectory
            .appending(path: "\(target.rawValue)-\(channel.rawValue).ipa")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    enum InstallError: LocalizedError {
        case badSource(String)
        case download(Int, String)

        var errorDescription: String? {
            switch self {
            case .badSource(let s): "Adresse de téléchargement invalide : \(s)"
            case .download(let code, let s): "Téléchargement refusé (\(code)) : \(s)"
            }
        }
    }

    /// Sort l'appel bloquant du pool coopératif — l'installation dure des
    /// dizaines de secondes.
    private func onBackground<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

// MARK: - Composants partagés
/// Segment maison plutôt que `Picker(.segmented)` : le contrôle système ne
/// laisse pas assez de prise sur le rayon ni sur la police, et le résultat
/// jurerait avec le reste. Le comportement, lui, reste identique.
/// Segment maison plutot que `Picker(.segmented)` : le controle systeme ne
/// laisse pas assez de prise sur le rayon ni sur la police.
///
/// Chaque item est une vue separee. Ce n'est pas de la coquetterie : empiler
/// trois ternaires dans une seule chaine de modificateurs fait exploser le
/// verificateur de types de Swift, qui abandonne avec un message peu clair.
/// Un sous-type par element garde chaque expression courte.
struct SegmentedRow<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let title: (T) -> String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                SegmentItem(
                    label: title(option),
                    active: option == selection
                ) {
                    withAnimation(PX.Motion.tap) { selection = option }
                }
            }
        }
        .padding(3)
        .background(segmentBackground)
        .overlay(segmentBorder)
    }

    private var segmentBackground: some View {
        RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
            .fill(PX.Color.night.opacity(0.55))
    }

    private var segmentBorder: some View {
        RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
            .strokeBorder(PX.Color.horizon, lineWidth: 1)
    }
}

private struct SegmentItem: View {
    let label: String
    let active: Bool
    let onTap: () -> Void

    private var weight: Font.Weight { active ? .semibold : .medium }
    private var ink: Color { active ? PX.Color.ink : PX.Color.inkFaint }
    private var fill: Color { active ? PX.Color.strata : .clear }
    private var shade: Color { active ? .black.opacity(0.35) : .clear }

    var body: some View {
        Text(label)
            .font(PX.Font.display(13, weight))
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(chip)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }

    private var chip: some View {
        RoundedRectangle(cornerRadius: PX.Radius.chip, style: .continuous)
            .fill(fill)
            .shadow(color: shade, radius: 6, y: 2)
    }
}
