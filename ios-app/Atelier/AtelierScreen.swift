import SwiftUI
import UniformTypeIdentifiers
import UIKit

// ═══════════════════════════════════════════════════════════════════════════
// ONGLET ATELIER
//
// Inspecter un IPA **avant** de l'installer — sans appareil, tout en local.
// L'outil qui manquait au sideloader : quelles architectures, l'app est-elle
// déchiffrée (sinon, resignée, elle ne tournera que sur l'appareil d'origine),
// quels frameworks embarqués, quel profil, quelles habilitations. Puis, d'un
// bouton, on l'envoie à l'Installeur.
//
// Le natif (`px_ipa_inspect`) lit l'archive zip et le Mach-O sur place. Aucune
// couleur signature ici : l'ambre reste au GPS. Vert = déchiffré / valide,
// rouge = chiffré / expiré, pervenche = neutre.
// ═══════════════════════════════════════════════════════════════════════════

struct AtelierScreen: View {

    @EnvironmentObject private var inbox: InstallInbox

    @State private var shown = false
    @State private var showingImport = false
    @State private var analyzing = false
    @State private var info: IPAInfo?
    @State private var ipaURL: URL?
    @State private var failure: String?
    @State private var showDylibs = false

    var body: some View {
        ZStack {
            PX.Color.canvas

            ScrollView {
                VStack(spacing: PX.Space.snug) {
                    ScreenHeader("Atelier", "Inspecte un IPA avant de l'installer.") {
                        if info != nil {
                            Button { showingImport = true } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(PX.Color.azimuth)
                            }
                        }
                    }
                    .appear(0, shown)

                    content
                }
                .padding(.horizontal, PX.Space.base)
                .padding(.bottom, 110)
            }
        }
        .onAppear { shown = true }
        .animation(PX.Motion.settle, value: info)
        .animation(PX.Motion.settle, value: analyzing)
        .sheet(isPresented: $showingImport) {
            DocumentPicker(contentTypes: [UTType(filenameExtension: "ipa") ?? .data, .data],
                           allowsMultiple: false, asCopy: true) { urls in
                showingImport = false
                if let src = urls.first { Task { await analyze(src) } }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Contenu

    @ViewBuilder
    private var content: some View {
        if analyzing {
            loadingCard.appear(1, shown)
        } else if let failure {
            banner("exclamationmark.triangle.fill", PX.Color.alert, "Lecture impossible", failure)
                .appear(1, shown)
            importButton.appear(2, shown)
        } else if let info {
            report(info)
        } else {
            emptyState.appear(1, shown)
        }
    }

    @ViewBuilder
    private func report(_ info: IPAInfo) -> some View {
        identityCard(info).appear(1, shown)
        factsCard(info).appear(2, shown)

        if !info.frameworks.isEmpty {
            listCard("Frameworks embarqués", "shippingbox", info.frameworks).appear(3, shown)
        }
        if !info.plugins.isEmpty {
            listCard("Extensions", "puzzlepiece.extension", info.plugins).appear(4, shown)
        }
        if let prov = info.provision {
            provisionCard(prov).appear(5, shown)
        }
        if !info.linkedDylibs.isEmpty {
            dylibsCard(info.linkedDylibs).appear(6, shown)
        }

        Button {
            guard let url = ipaURL else { return }
            inbox.installLocal(path: url.path, name: info.name)
        } label: {
            Label("Envoyer à l'Installeur", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(ProminentButtonStyle())
        .appear(7, shown)
        .disabled(ipaURL == nil)

        HStack(spacing: PX.Space.snug) {
            Button {
                UIPasteboard.general.string = info.bundleId
            } label: {
                Label("Copier l'identifiant", systemImage: "doc.on.doc")
            }
            .buttonStyle(SecondaryButtonStyle())

            ShareLink(item: reportText(info)) {
                Label("Partager le rapport", systemImage: "square.and.arrow.up")
                    .font(PX.Font.display(14, .semibold))
                    .foregroundStyle(PX.Color.inkMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule(style: .continuous).fill(.white.opacity(0.05)))
                    .overlay(Capsule(style: .continuous).strokeBorder(PX.Color.horizon, lineWidth: 1))
            }
        }
        .appear(8, shown)
    }

    /// Résumé texte de l'inspection, pour le presse-papiers / le partage.
    private func reportText(_ info: IPAInfo) -> String {
        var lines: [String] = [
            "\(info.name) — inspection Parallax",
            "Identifiant : \(info.bundleId)",
            "Version : \(info.versionText)",
            "iOS minimum : \(info.minOS.isEmpty ? "—" : info.minOS)",
            "Architectures : \(info.archs.isEmpty ? "—" : info.archs.joined(separator: ", "))",
            "Binaire : \(info.encryptionText)",
            "Taille : \(info.fileSizeText)",
        ]
        if !info.frameworks.isEmpty {
            lines.append("Frameworks : \(info.frameworks.joined(separator: ", "))")
        }
        if let p = info.provision {
            lines.append("Profil : \(p.typeLabel) · \(p.team) · \(p.validityText)")
        }
        return lines.joined(separator: "\n")
    }

    private func identityCard(_ info: IPAInfo) -> some View {
        HStack(spacing: PX.Space.base) {
            IconTile(system: "app.badge.checkmark", tint: PX.Color.azimuth, size: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text(info.name)
                    .font(PX.Font.display(20, .bold))
                    .foregroundStyle(PX.Color.ink)
                    .lineLimit(2)
                Text(info.bundleId)
                    .font(PX.Font.mono(11.5))
                    .foregroundStyle(PX.Color.inkMuted)
                    .lineLimit(1).truncationMode(.middle)
                Text("v\(info.versionText)")
                    .font(PX.Font.mono(11))
                    .foregroundStyle(PX.Color.inkFaint)
            }
            Spacer(minLength: 0)
        }
        .padding(PX.Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(emphasis: true)
    }

    private func factsCard(_ info: IPAInfo) -> some View {
        VStack(alignment: .leading, spacing: PX.Space.snug) {
            // Architectures en pastilles.
            HStack(alignment: .top) {
                Text("Architectures").font(PX.Font.body(13)).foregroundStyle(PX.Color.inkMuted)
                Spacer()
                if info.archs.isEmpty {
                    Text("—").font(PX.Font.mono(12)).foregroundStyle(PX.Color.inkFaint)
                } else {
                    HStack(spacing: 6) {
                        ForEach(info.archs, id: \.self) { a in
                            Text(a)
                                .font(PX.Font.mono(11, .semibold))
                                .foregroundStyle(PX.Color.azimuth)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(PX.Color.azimuth.opacity(0.14)))
                        }
                    }
                }
            }
            rowDivider
            // Chiffrement — le fait déterminant pour une réinstallation.
            HStack {
                Text("Binaire").font(PX.Font.body(13)).foregroundStyle(PX.Color.inkMuted)
                Spacer()
                Tag(info.encryptionText,
                    color: info.encrypted ? PX.Color.alert : PX.Color.verdant,
                    icon: info.encrypted ? "lock.fill" : "lock.open.fill")
            }
            rowDivider
            factRow("iOS minimum", info.minOS.isEmpty ? "—" : info.minOS, mono: true)
            rowDivider
            factRow("Compatible", info.deviceFamilyText)
            rowDivider
            factRow("Taille", info.fileSizeText, mono: true)
            if info.payloadApps > 1 {
                rowDivider
                factRow("Apps dans le Payload", "\(info.payloadApps)", mono: true)
            }
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private func provisionCard(_ p: IPAProvision) -> some View {
        VStack(alignment: .leading, spacing: PX.Space.snug) {
            HStack {
                SectionLabel("Profil de provisionnement")
                Spacer()
                Tag(p.typeLabel, color: PX.Color.azimuth, icon: "signature")
            }
            rowDivider
            factRow("Équipe", p.team.isEmpty ? "—" : p.team)
            rowDivider
            factRow("App ID", p.appId.isEmpty ? "—" : p.appId, mono: true)
            rowDivider
            HStack {
                Text("Validité").font(PX.Font.body(13)).foregroundStyle(PX.Color.inkMuted)
                Spacer()
                Text(p.validityText)
                    .font(PX.Font.body(13, .semibold))
                    .foregroundStyle(p.isExpired ? PX.Color.alert : PX.Color.verdant)
            }
            if p.devices > 0 {
                rowDivider
                factRow("Appareils", "\(p.devices)", mono: true)
            }
            rowDivider
            HStack {
                Text("get-task-allow").font(PX.Font.mono(11.5)).foregroundStyle(PX.Color.inkMuted)
                Spacer()
                Image(systemName: p.getTaskAllow ? "checkmark.circle.fill" : "minus.circle")
                    .foregroundStyle(p.getTaskAllow ? PX.Color.verdant : PX.Color.inkFaint)
            }
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private func listCard(_ title: String, _ icon: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: PX.Space.tight) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(PX.Color.inkMuted)
                SectionLabel("\(title) · \(items.count)")
            }
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(PX.Font.mono(12))
                    .foregroundStyle(PX.Color.ink)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(PX.Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func dylibsCard(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: PX.Space.tight) {
            Button { withAnimation(PX.Motion.settle) { showDylibs.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "link").font(.system(size: 12)).foregroundStyle(PX.Color.inkMuted)
                    SectionLabel("Bibliothèques liées · \(items.count)")
                    Spacer()
                    Image(systemName: showDylibs ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PX.Color.inkFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showDylibs {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(PX.Font.mono(11))
                        .foregroundStyle(PX.Color.inkMuted)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(PX.Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var emptyState: some View {
        VStack(spacing: PX.Space.base) {
            banner("wrench.and.screwdriver", PX.Color.azimuth, "Aucun IPA chargé",
                   "Importe un fichier .ipa pour l'inspecter : architectures, chiffrement, frameworks, profil.")
            importButton
        }
    }

    private var importButton: some View {
        Button { showingImport = true } label: {
            Label("Importer un IPA", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(ProminentButtonStyle())
    }

    private var loadingCard: some View {
        HStack(spacing: PX.Space.snug) {
            ProgressView().tint(PX.Color.azimuth)
            Text("Inspection de l'archive…").font(PX.Font.body(13)).foregroundStyle(PX.Color.inkMuted)
            Spacer()
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private var rowDivider: some View {
        Divider().overlay(PX.Color.horizon)
    }

    private func factRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack {
            Text(label).font(PX.Font.body(13)).foregroundStyle(PX.Color.inkMuted)
            Spacer()
            Text(value)
                .font(mono ? PX.Font.mono(12) : PX.Font.body(13, .medium))
                .foregroundStyle(PX.Color.ink)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func banner(_ icon: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(spacing: PX.Space.snug) {
            IconTile(system: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(PX.Font.display(15, .semibold)).foregroundStyle(PX.Color.ink)
                Text(detail).font(PX.Font.body(12)).foregroundStyle(PX.Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(PX.Space.base)
        .glassCard(emphasis: true)
        .overlay(RoundedRectangle(cornerRadius: PX.Radius.card, style: .continuous)
            .strokeBorder(tint.opacity(0.34), lineWidth: 1))
    }

    // MARK: - Analyse

    private func analyze(_ src: URL) async {
        analyzing = true
        failure = nil
        info = nil
        defer { analyzing = false }

        // Copie stable : l'IPA sert à l'inspection puis, éventuellement, à
        // l'Installeur — on ne dépend pas du temporaire du sélecteur.
        let name = src.deletingPathExtension().lastPathComponent
        let dest = URL.temporaryDirectory.appending(path: "atelier-\(name).ipa")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
        } catch {
            // Repli : on inspecte la source telle quelle.
            ipaURL = src
            await run(on: src)
            return
        }
        ipaURL = dest
        await run(on: dest)
    }

    private func run(on url: URL) async {
        let result = await withCheckedContinuation { (c: CheckedContinuation<IPAInfo?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(returning: FFI.inspectIPA(path: url.path))
            }
        }
        if let result {
            withAnimation(PX.Motion.settle) { info = result }
        } else {
            failure = "L'archive n'a pas pu être lue — est-ce bien un .ipa ?"
        }
    }
}
