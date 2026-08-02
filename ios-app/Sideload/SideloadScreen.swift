import SwiftUI
import UIKit
import UniformTypeIdentifiers

// ═══════════════════════════════════════════════════════════════════════════
// ONGLET INSTALLER
//
// La fonctionnalité principale : mettre SideStore, et LiveContainer,
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
    @EnvironmentObject private var account: AppleAccountModel
    @StateObject private var log = LogBridge.shared

    @State private var target: InstallTarget = .sideStore
    @State private var channel: Channel = .stable
    @State private var installing = false
    @State private var shown = false
    @State private var progress: InstallProgress?
    @State private var failure: String?
    @State private var installed: String?
    /// Incrémenté à chaque aboutissement, pour rejouer le sceau.
    @State private var doneCount = 0
    /// Respiration de la lueur sur l'étape en cours.
    @State private var pulse = false
    /// Dernières lignes du cœur natif, pour que l'attente soit lisible.
    @State private var trace: [String] = []
    /// Permet de corriger une adresse devenue fausse sans reconstruire l'app.
    @AppStorage("ipaSourceOverride") private var sourceOverride: String = ""

    // ── Cible « Autre IPA » ────────────────────────────────────────────────
    /// IPA importé depuis Fichiers, déjà copié en zone temporaire (l'accès
    /// sécurisé ne dure pas au-delà du callback, d'où la copie immédiate).
    @State private var customIPA: URL?
    @State private var customName = ""
    @State private var customURLText = ""
    /// Tweaks (.dylib/.deb) à injecter dans l'IPA « Autre » avant signature.
    @State private var tweaks: [URL] = []
    /// Frameworks & extensions (.dylib/.deb) à embarquer — même mécanique
    /// d'injection, liste séparée pour coller à l'organisation de Feather.
    @State private var frameworks: [URL] = []
    /// Un seul sélecteur partagé ; on mémorise ce qu'on importe.
    private enum ImportKind { case ipa, tweak, framework }
    @State private var importKind: ImportKind = .ipa
    @State private var showingImporter = false
    /// Section « Avancé » façon Feather : le groupe Modify et ses sous-listes se
    /// déplient à la demande.
    @State private var modifyOpen = true
    @State private var tweaksOpen = false
    @State private var frameworksOpen = false
    /// Options d'injection façon Feather (écran Tweaks de la capture).
    @State private var injectionPath = "@executable_path"
    @State private var injectionFolder = "Frameworks"
    @State private var injectExtensions = false

    private let injectionPaths = ["@executable_path", "@loader_path", "@rpath"]
    private let injectionFolders = ["Frameworks", "Dylibs", "Tweaks"]

    enum InstallTarget: String, CaseIterable {
        case sideStore = "SideStore"
        case liveContainer = "LiveContainer"
        /// N'importe quel IPA fourni par l'utilisateur — fichier ou URL. Signé
        /// avec son propre compte, comme le reste : aucun cert partagé.
        case custom = "Autre IPA"

        /// SideStore publie un build stable et un nightly. LiveContainer est une
        /// app compagnon distincte (dépôt LiveContainer/LiveContainer), avec un
        /// seul canal — d'où l'URL fixe. `custom` n'a pas d'URL prédéfinie :
        /// elle vient de l'import ou du champ, gérée à part.
        /// C'est Rust qui confirmera le `SpecialApp` détecté dans l'IPA signé.
        func url(for channel: Channel) -> String {
            switch self {
            case .sideStore:
                switch channel {
                case .stable:
                    "https://github.com/SideStore/SideStore/releases/latest/download/SideStore.ipa"
                case .nightly:
                    "https://github.com/SideStore/SideStore/releases/download/nightly/SideStore.ipa"
                }
            case .liveContainer:
                "https://github.com/LiveContainer/LiveContainer/releases/latest/download/LiveContainer.ipa"
            case .custom:
                ""
            }
        }

        /// Seul SideStore a des canaux (stable/nightly).
        var hasChannels: Bool { self == .sideStore }

        var blurb: String {
            switch self {
            case .sideStore:
                "Le magasin : installe et re-signe tes apps tout seul, tous les sept jours."
            case .liveContainer:
                "Le conteneur : exécute d'autres apps sans consommer d'emplacement de signature. À poser après SideStore."
            case .custom:
                "N'importe quel IPA : importe un fichier ou colle une URL. Signé avec ton compte, installé sur ton appareil."
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

        /// Numéro de l'étape **en cours**. Une étape est cochée quand
        /// `phase.step` la dépasse, d'où le 4 pour `.done` : sans lui la
        /// troisième restait éternellement active, jamais validée.
        var step: Int {
            switch self {
            case .needsAccount:              1
            case .needsPairing, .needsLink:  2
            case .ready, .working:           3
            case .done:                      4
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
                    ScreenHeader("Installer", "Signé sur cet appareil, avec ton compte.")
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
        .onAppear {
            shown = true
            withAnimation(PX.Motion.breathe) { pulse = true }
        }
        .animation(PX.Motion.settle, value: installing)
        .animation(PX.Motion.acquire, value: installed)
        .animation(PX.Motion.settle, value: failure)
        .onReceive(NotificationCenter.default.publisher(for: .installProgress)) { note in
            guard let update = note.object as? InstallProgress else { return }
            withAnimation(PX.Motion.settle) { progress = update }
        }
        .onReceive(log.$lines) { lines in
            guard installing, let last = lines.last else { return }
            absorb(last)
        }
        // Sélecteur UIKit (`UIDocumentPickerViewController`) plutôt que
        // `.fileImporter` : sur cet appareil ce dernier ne rendait jamais son
        // résultat (le fichier « ne se sélectionnait pas »). Avec `asCopy:true`,
        // iOS copie le fichier dans notre bac à sable — pas d'accès sécurisé à
        // gérer, et le callback du délégué est fiable.
        .sheet(isPresented: $showingImporter) {
            DocumentPicker(
                contentTypes: importKind == .ipa
                    ? [UTType(filenameExtension: "ipa") ?? .data]
                    // Tweaks & frameworks : .dylib (palier 1) et .deb (palier 2/3).
                    : [UTType(filenameExtension: "dylib"),
                       UTType(filenameExtension: "deb")].compactMap { $0 } + [.data],
                allowsMultiple: importKind != .ipa
            ) { urls in
                handlePicked(urls)
            }
            .ignoresSafeArea()
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
                    IconTile(system: phase.icon, tint: phase.tint)
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
                // La lueur ne vit que sur l'étape en cours. C'est ce qui fait
                // qu'on la trouve sans la chercher, et pourquoi il ne doit y en
                // avoir qu'une : deux lueurs, et plus aucune ne désigne rien.
                Circle()
                    .fill(PX.Color.azimuth)
                    .frame(width: 28, height: 28)
                    .blur(radius: 11)
                    .opacity(active ? (pulse ? 0.55 : 0.22) : 0)

                Circle()
                    .fill(done ? PX.Color.verdant.opacity(0.18)
                               : active ? PX.Color.azimuth.opacity(0.20)
                                        : Color.white.opacity(0.04))
                    .frame(width: 28, height: 28)

                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(PX.Color.verdant)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    Text("\(number)")
                        .font(PX.Font.mono(12, .bold))
                        .foregroundStyle(active ? PX.Color.azimuth : PX.Color.inkFaint)
                        .transition(.opacity)
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
        .animation(PX.Motion.acquire, value: phase.step)
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

            if !trace.isEmpty {
                Divider().overlay(PX.Color.horizon)
                traceWindow
            }
        }
        .padding(PX.Space.base)
        .glassCard()
        .animation(PX.Motion.settle, value: progress)
    }

    /// Fenêtre de journal, six lignes glissantes.
    ///
    /// Une barre qui avance sans rien dire, c'est une attente ; une barre qui
    /// nomme ce qu'elle fait, c'est un travail. On ne montre donc pas *tout* le
    /// journal — la signature à elle seule crache des centaines de lignes — mais
    /// ce qui a du sens vu d'ici : requêtes Apple, frameworks signés, transfert.
    ///
    /// En mono, parce que ce sont les mots de la machine, pas les nôtres.
    private var traceWindow: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(trace.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(index == trace.count - 1 ? PX.Color.azimuth : PX.Color.inkFaint)
                        .frame(width: 3, height: 3)
                        .padding(.top, 5)
                    Text(line)
                        .font(PX.Font.mono(9.5))
                        .foregroundStyle(index == trace.count - 1
                                         ? PX.Color.inkMuted : PX.Color.inkFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // La ligne la plus ancienne s'efface au lieu de disparaître.
                .opacity(index == 0 && trace.count == Self.traceDepth ? 0.45 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(PX.Motion.settle, value: trace)
    }

    private static let traceDepth = 6

    /// Ne retient que ce qui informe. Le reste — des centaines de lignes de
    /// scellement de ressources — noierait le peu qui compte.
    private func absorb(_ line: String) {
        let interesting = [
            "Registered app IDs", "provisioning", "Acquired", "certificate",
            "Signing ", "App signed", "IPA reconstitué", "Device is a development",
            "Transfert", "Installation", "install", "Enregistrement", "Signature",
            "Préparation", "Téléchargement",
        ]
        guard interesting.contains(where: { line.localizedCaseInsensitiveContains($0) })
        else { return }

        // On coupe l'horodatage et le module : à cette taille, seule l'action
        // tient sur la ligne.
        var text = line
        if let range = text.range(of: "  ") { text = String(text[range.upperBound...]) }
        text = text.replacingOccurrences(of: "INFO ", with: "")
        if let colon = text.range(of: ": "), text.distance(from: text.startIndex, to: colon.lowerBound) < 42 {
            text = String(text[colon.upperBound...])
        }

        withAnimation(PX.Motion.settle) {
            trace.append(String(text.prefix(90)))
            if trace.count > Self.traceDepth { trace.removeFirst(trace.count - Self.traceDepth) }
        }
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

            Text(target.blurb)
                .font(PX.Font.body(12))
                .foregroundStyle(PX.Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if target.hasChannels {
                SegmentedRow(selection: $channel, options: Channel.allCases) { $0.rawValue }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if target == .custom {
                customSection
                    .transition(.opacity)
            }
        }
        .padding(PX.Space.base)
        .glassCard()
        .animation(PX.Motion.settle, value: target)
        .animation(PX.Motion.settle, value: modifyOpen)
        .animation(PX.Motion.settle, value: tweaksOpen)
        .animation(PX.Motion.settle, value: frameworksOpen)
    }

    // MARK: - Section « Autre IPA » façon Feather

    /// Source (fichier/URL) puis une section **Avancé** en listes groupées, dans
    /// l'esprit de Feather : un groupe *Modify* pliable qui range les paliers
    /// d'injection — Tweaks, Frameworks & extensions — et rappelle que les
    /// dylibs déjà présents sont conservés.
    private var customSection: some View {
        VStack(alignment: .leading, spacing: PX.Space.base) {
            // ── Source ──
            insetGroup {
                Button { importKind = .ipa; showingImporter = true } label: {
                    row(icon: customName.isEmpty ? "folder.fill" : "doc.fill",
                        title: customName.isEmpty ? "Choisir un fichier .ipa" : customName,
                        subtitle: customName.isEmpty ? "depuis Fichiers" : "sélectionné",
                        trailing: chevron(open: false))
                }
                .buttonStyle(.plain)

                rowDivider

                HStack(spacing: PX.Space.snug) {
                    IconTile(system: "link", size: 32)
                    TextField("ou coller une URL directe .ipa", text: $customURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(PX.Font.mono(12.5))
                        .foregroundStyle(PX.Color.ink)
                        .onChange(of: customURLText) { _, value in
                            if !value.isEmpty { customIPA = nil; customName = "" }
                        }
                }
                .padding(.horizontal, PX.Space.base)
                .padding(.vertical, 10)
            }

            // ── Avancé ──
            Text("Avancé")
                .font(PX.Font.display(20, .heavy))
                .tracking(-0.2)
                .foregroundStyle(PX.Color.ink)
                .padding(.top, PX.Space.hair)

            insetGroup {
                Button { modifyOpen.toggle() } label: {
                    row(icon: "slider.horizontal.3", title: "Modify",
                        subtitle: nil, trailing: chevron(open: modifyOpen))
                }
                .buttonStyle(.plain)

                if modifyOpen {
                    rowDivider
                    modifyEntry(icon: "puzzlepiece.extension.fill", title: "Tweaks",
                                count: tweaks.count, open: $tweaksOpen)
                    if tweaksOpen {
                        fileList(tweaks) { url in tweaks.removeAll { $0 == url } }
                        addButton("Ajouter (.dylib / .deb)") {
                            importKind = .tweak; showingImporter = true
                        }
                    }

                    rowDivider
                    modifyEntry(icon: "shippingbox.fill", title: "Frameworks & extensions",
                                count: frameworks.count, open: $frameworksOpen)
                    if frameworksOpen {
                        fileList(frameworks) { url in frameworks.removeAll { $0 == url } }
                        addButton("Ajouter (.dylib / .deb)") {
                            importKind = .framework; showingImporter = true
                        }
                    }

                    rowDivider
                    row(icon: "doc.on.doc.fill", title: "Dylibs existants",
                        subtitle: "conservés et re-signés automatiquement",
                        trailing: EmptyView())
                }
            }

            // ── Injection (réglages fins, façon Feather) ──
            Text("Injection")
                .font(PX.Font.display(20, .heavy))
                .tracking(-0.2)
                .foregroundStyle(PX.Color.ink)
                .padding(.top, PX.Space.hair)

            insetGroup {
                Menu {
                    ForEach(injectionPaths, id: \.self) { path in
                        Button {
                            injectionPath = path
                        } label: {
                            if path == injectionPath {
                                Label(path, systemImage: "checkmark")
                            } else {
                                Text(path)
                            }
                        }
                    }
                } label: {
                    row(icon: "curlybraces", title: "Injection Path",
                        subtitle: injectionPath, trailing: upDown)
                }

                rowDivider

                Menu {
                    ForEach(injectionFolders, id: \.self) { folder in
                        Button {
                            injectionFolder = folder
                        } label: {
                            if folder == injectionFolder {
                                Label(folder, systemImage: "checkmark")
                            } else {
                                Text(folder)
                            }
                        }
                    }
                } label: {
                    row(icon: "folder.fill", title: "Injection Folder",
                        subtitle: "/\(injectionFolder)/", trailing: upDown)
                }

                rowDivider

                HStack(spacing: PX.Space.snug) {
                    IconTile(system: "syringe.fill", size: 32)
                    Text("Inject into Extensions")
                        .font(PX.Font.display(14.5, .semibold))
                        .foregroundStyle(PX.Color.ink)
                    Spacer(minLength: PX.Space.tight)
                    Toggle("", isOn: $injectExtensions)
                        .labelsHidden()
                        .tint(PX.Color.azimuth)
                }
                .padding(.horizontal, PX.Space.base)
                .padding(.vertical, 9)
            }

            Text("Tweaks et frameworks sont injectés avant signature. Un .deb complet : la Substrate est réécrite vers ElleKit et les dépendances embarquées (paliers 1-2-3). Ajoute ElleKit (.deb) si un tweak en dépend.")
                .font(PX.Font.body(11))
                .foregroundStyle(PX.Color.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // ── Briques de liste groupée ───────────────────────────────────────────

    /// Conteneur de groupe inséré *dans* une carte : fond sombre à filets, coins
    /// arrondis. Distinct du `glassCard` pour ne pas empiler deux verres.
    private func insetGroup<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
                    .fill(PX.Color.night.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
                    .strokeBorder(PX.Color.horizon, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous))
    }

    private var rowDivider: some View {
        Divider().overlay(PX.Color.horizon).padding(.leading, 56)
    }

    /// Ligne façon Réglages : tuile d'icône, titre (+ sous-titre), accessoire.
    private func row(icon: String, tint: Color = PX.Color.azimuth,
                     title: String, subtitle: String?, trailing: some View) -> some View {
        HStack(spacing: PX.Space.snug) {
            IconTile(system: icon, tint: tint, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(PX.Font.display(14.5, .semibold))
                    .foregroundStyle(PX.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(PX.Font.body(11.5))
                        .foregroundStyle(PX.Color.inkFaint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: PX.Space.tight)
            trailing
        }
        .padding(.horizontal, PX.Space.base)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private func modifyEntry(icon: String, title: String,
                             count: Int, open: Binding<Bool>) -> some View {
        Button { open.wrappedValue.toggle() } label: {
            row(icon: icon, title: title,
                subtitle: count == 0 ? nil
                    : (count == 1 ? "1 élément" : "\(count) éléments"),
                trailing: HStack(spacing: 8) {
                    if count > 0 {
                        Text("\(count)")
                            .font(PX.Font.display(11, .bold))
                            .foregroundStyle(PX.Color.azimuth)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(PX.Color.azimuth.opacity(0.16)))
                    }
                    chevron(open: open.wrappedValue)
                })
        }
        .buttonStyle(.plain)
    }

    private func chevron(open: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(PX.Color.inkFaint)
            .rotationEffect(.degrees(open ? 90 : 0))
    }

    /// Accessoire d'une ligne à menu (« ⌄⌃ »), comme les sélecteurs de Feather.
    private var upDown: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(PX.Color.inkFaint)
    }

    @ViewBuilder
    private func fileList(_ urls: [URL], remove: @escaping (URL) -> Void) -> some View {
        VStack(spacing: 7) {
            if urls.isEmpty {
                Text("Aucun fichier ajouté")
                    .font(PX.Font.body(11.5))
                    .foregroundStyle(PX.Color.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(urls, id: \.self) { url in
                    HStack(spacing: PX.Space.tight) {
                        Image(systemName: url.pathExtension.lowercased() == "deb"
                              ? "shippingbox" : "puzzlepiece.extension")
                            .font(.system(size: 11))
                            .foregroundStyle(PX.Color.azimuth)
                        Text(url.lastPathComponent)
                            .font(PX.Font.mono(11))
                            .foregroundStyle(PX.Color.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button { remove(url) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(PX.Color.inkFaint)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.leading, 56)
        .padding(.trailing, PX.Space.base)
        .padding(.bottom, PX.Space.tight)
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
        }
        .buttonStyle(SecondaryButtonStyle())
        .padding(.leading, 56)
        .padding(.trailing, PX.Space.base)
        .padding(.bottom, PX.Space.snug)
    }

    private var actionLabel: String {
        switch phase {
        case .working(let percent, _): "Installation… \(percent) %"
        case .done:                    target == .custom ? "Réinstaller" : "Réinstaller \(target.rawValue)"
        case .needsAccount:            "Connecte ton compte Apple"
        case .needsPairing:            "Jumelage requis"
        case .needsLink:               "Établis le lien"
        default:                       target == .custom ? "Installer l'IPA" : "Installer \(target.rawValue)"
        }
    }

    /// Nom affiché après installation quand Rust ne détecte pas d'app spéciale.
    private var installedLabel: String {
        if target == .custom { return customName.isEmpty ? "l'application" : customName }
        return target.rawValue
    }

    /// Les trois conditions réelles, dans l'ordre où l'utilisateur les remplit :
    /// compte connecté, lien établi, identité de l'appareil connue. Les champs
    /// de mot de passe locaux ne conditionnent plus rien — la session vient du
    /// modèle partagé.
    private var canInstall: Bool {
        guard account.isConnected, connection.tunnelPointer != nil, !installing else { return false }
        if target == .custom {
            return customIPA != nil
                || !customURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
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
        trace = []
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

            let ipa = try await resolveIPA()
            let dylibs = target == .custom ? (tweaks + frameworks).map(\.path) : []
            let special = try await onBackground {
                try FFI.installIPA(
                    session: session, tunnel: tunnel,
                    ipaPath: ipa.path, device: device, dylibs: dylibs,
                    injectionPath: injectionPath,
                    injectionFolder: injectionFolder,
                    injectIntoExtensions: injectExtensions
                )
            }
            installed = special.isEmpty ? installedLabel : special
            doneCount += 1
            LogBridge.shared.note("installation terminée : \(installed ?? "")")
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Reçoit les fichiers du sélecteur UIKit. Avec `asCopy:true`, iOS les a déjà
    /// posés dans notre bac à sable (`Inbox`) : on n'a donc pas d'accès sécurisé
    /// à ouvrir. On les recopie tout de même sous un nom propre en zone
    /// temporaire, pour un chemin stable qui survit à l'installation.
    private func handlePicked(_ urls: [URL]) {
        showingImporter = false
        guard !urls.isEmpty else { return }
        do {
            switch importKind {
            case .ipa:
                if let first = urls.first {
                    let dest = try copyIntoTemp(first)
                    withAnimation(PX.Motion.settle) {
                        customIPA = dest
                        customName = first.lastPathComponent
                        customURLText = ""
                    }
                }
            case .tweak:
                for src in urls {
                    let dest = try copyIntoTemp(src)
                    if !tweaks.contains(dest) {
                        withAnimation(PX.Motion.settle) { tweaks.append(dest) }
                    }
                }
            case .framework:
                for src in urls {
                    let dest = try copyIntoTemp(src)
                    if !frameworks.contains(dest) {
                        withAnimation(PX.Motion.settle) { frameworks.append(dest) }
                    }
                }
            }
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Recopie un fichier livré par le sélecteur (déjà local grâce à `asCopy`)
    /// sous un chemin temporaire stable et à nom propre.
    private func copyIntoTemp(_ src: URL) throws -> URL {
        let dest = URL.temporaryDirectory.appending(path: src.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: src, to: dest)
        return dest
    }

    /// Résout l'IPA à installer, quelle que soit la cible :
    /// - `custom` : le fichier importé (déjà local) ou l'URL collée ;
    /// - SideStore / LiveContainer : l'URL du projet (ou la surcharge Réglages).
    private func resolveIPA() async throws -> URL {
        if target == .custom {
            if let local = customIPA { return local }
            let text = customURLText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true else {
                throw InstallError.badSource(text.isEmpty ? "aucun fichier ni URL" : text)
            }
            return try await downloadURL(url, name: "custom")
        }

        let source = sourceOverride.isEmpty ? target.url(for: channel) : sourceOverride
        guard let url = URL(string: source) else { throw InstallError.badSource(source) }
        return try await downloadURL(url, name: "\(target.rawValue)-\(channel.rawValue)")
    }

    /// Télécharge une URL vers un fichier local stable (URLSession efface son
    /// temporaire à la sortie du scope, donc on le déplace avant de le confier
    /// à Rust). Le nom est assaini pour ne pas casser le chemin.
    private func downloadURL(_ url: URL, name: String) async throws -> URL {
        progress = InstallProgress(percent: 0, label: "Téléchargement…")
        let (temporary, response) = try await URLSession.shared.download(from: url)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.download(http.statusCode, url.absoluteString)
        }

        let safe = name.replacingOccurrences(of: "/", with: "-")
        let destination = URL.temporaryDirectory.appending(path: "\(safe).ipa")
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

// MARK: - Sélecteur de fichiers (UIKit)

/// Enrobage de `UIDocumentPickerViewController`. On l'utilise à la place de
/// `.fileImporter`, qui, sur l'appareil de l'auteur, ne renvoyait jamais le
/// fichier choisi (« ça ne se sélectionne pas »).
///
/// `asCopy: true` demande à iOS de **copier** le fichier dans notre bac à sable
/// avant de nous le rendre : plus besoin d'ouvrir un accès sécurisé (source
/// classique d'échec silencieux), et l'URL reçue est directement lisible.
struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let allowsMultiple: Bool
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes, asCopy: true
        )
        picker.allowsMultipleSelection = allowsMultiple
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick([])
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
