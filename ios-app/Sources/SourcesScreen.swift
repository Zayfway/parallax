import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
// ONGLET SOURCES
//
// Un magasin, à la façon d'AltStore / SideStore : on ajoute l'URL d'une
// **source** (un JSON qui décrit une liste d'apps), et Parallax en affiche le
// catalogue — icône, développeur, description, version. Toucher « Installer »
// ne signe rien ici : ça dépose l'IPA dans l'**Installeur**, qui applique la
// méthode de signature choisie (compte Apple ou certificat importé). Sources
// est une vitrine ; l'Installeur reste le seul atelier.
//
// Le format lu est celui d'AltStore (champ `apps[]`, `versions[]` récent ou
// `downloadURL` hérité) — la même source marche donc dans les deux apps.
// ═══════════════════════════════════════════════════════════════════════════

struct SourcesScreen: View {

    @EnvironmentObject private var inbox: InstallInbox
    @StateObject private var store = SourceStore()

    @State private var shown = false
    @State private var query = ""
    @State private var addingSource = false
    @State private var newSourceURL = ""
    @State private var selected: SourceApp?
    @State private var pendingRemove: String?

    var body: some View {
        ZStack {
            PX.Color.canvas

            ScrollView {
                VStack(spacing: PX.Space.snug) {
                    ScreenHeader("Sources", "Des catalogues d'apps à installer.") {
                        headerMenu
                    }
                    .appear(0, shown)

                    if store.urls.isEmpty {
                        emptyState.appear(1, shown)
                    } else {
                        searchField.appear(1, shown)
                        content
                    }
                }
                .padding(.horizontal, PX.Space.base)
                .padding(.bottom, 110)
            }
            .refreshable { await store.refresh() }
        }
        .onAppear {
            shown = true
            if store.feeds.isEmpty && !store.urls.isEmpty { Task { await store.refresh() } }
        }
        .animation(PX.Motion.settle, value: store.feeds)
        .animation(PX.Motion.settle, value: query)
        .sheet(isPresented: $addingSource) {
            addSourceSheet.presentationDetents([.medium, .large])
                .presentationBackground(PX.Color.abyss)
        }
        .sheet(item: $selected) { app in
            SourceAppDetail(app: app) { url, name in
                selected = nil
                inbox.install(url: url, name: name)
            }
            .presentationDetents([.large])
            .presentationBackground(PX.Color.abyss)
            .presentationDragIndicator(.hidden)
        }
        .confirmationDialog(
            "Retirer cette source ?",
            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemove
        ) { url in
            Button("Retirer", role: .destructive) {
                let u = url; pendingRemove = nil; store.remove(u)
            }
            Button("Annuler", role: .cancel) { pendingRemove = nil }
        }
    }

    private var headerMenu: some View {
        Menu {
            Button { newSourceURL = ""; addingSource = true } label: {
                Label("Ajouter une source", systemImage: "plus")
            }
            Button { Task { await store.refresh() } } label: {
                Label("Rafraîchir", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PX.Color.azimuth)
        }
    }

    // MARK: - Contenu

    @ViewBuilder
    private var content: some View {
        if store.loading && store.feeds.allSatisfy({ $0.source == nil && $0.error == nil }) {
            loadingCard.appear(2, shown)
        } else {
            ForEach(Array(store.feeds.enumerated()), id: \.element.id) { i, feed in
                feedSection(feed).appear(2 + i, shown)
            }
        }
    }

    private func feedSection(_ feed: SourceStore.Feed) -> some View {
        VStack(alignment: .leading, spacing: PX.Space.tight) {
            HStack {
                SectionLabel(feed.source?.name ?? shortURL(feed.url))
                Spacer()
                Button { pendingRemove = feed.url } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(PX.Color.inkFaint)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, PX.Space.snug)

            if let error = feed.error {
                banner("exclamationmark.triangle.fill", PX.Color.alert, "Source injoignable", error)
            } else {
                let apps = filtered(feed.source?.apps ?? [])
                if apps.isEmpty {
                    banner("magnifyingglass", PX.Color.inkFaint, "Rien à afficher",
                           query.isEmpty ? "Cette source ne liste aucune app." : "Aucun résultat pour « \(query) ».")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                            appRow(app)
                            if index < apps.count - 1 {
                                Divider().overlay(PX.Color.horizon).padding(.leading, 68)
                            }
                        }
                    }
                    .glassCard()
                }
            }
        }
    }

    private func appRow(_ app: SourceApp) -> some View {
        Button { selected = app } label: {
            HStack(spacing: PX.Space.snug) {
                SourceIcon(urlString: app.iconURL, tint: app.accent, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(PX.Font.display(15, .semibold))
                        .foregroundStyle(PX.Color.ink)
                        .lineLimit(1)
                    if let sub = app.subtitle ?? app.developerName, !sub.isEmpty {
                        Text(sub)
                            .font(PX.Font.body(12))
                            .foregroundStyle(PX.Color.inkMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: PX.Space.tight)
                Text("OBTENIR")
                    .font(PX.Font.display(11, .heavy))
                    .foregroundStyle(PX.Color.azimuth)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(PX.Color.azimuth.opacity(0.14)))
            }
            .padding(.horizontal, PX.Space.base)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: PX.Space.tight) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PX.Color.inkFaint)
            TextField("Rechercher une app", text: $query)
                .font(PX.Font.body(15))
                .foregroundStyle(PX.Color.ink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(PX.Color.inkFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, PX.Space.base)
        .padding(.vertical, 11)
        .glassCard()
    }

    private var emptyState: some View {
        VStack(spacing: PX.Space.base) {
            banner("bag.badge.plus", PX.Color.azimuth, "Aucune source",
                   "Ajoute l'URL d'une source d'apps (format AltStore) pour parcourir son catalogue.")

            VStack(alignment: .leading, spacing: PX.Space.tight) {
                SectionLabel("Suggestions")
                    .padding(.horizontal, PX.Space.snug)
                VStack(spacing: 0) {
                    ForEach(Array(SourceStore.suggestions.enumerated()), id: \.offset) { i, s in
                        Button { store.add(s.url) } label: {
                            HStack(spacing: PX.Space.snug) {
                                IconTile(system: "link", tint: PX.Color.azimuth, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name).font(PX.Font.display(14, .semibold)).foregroundStyle(PX.Color.ink)
                                    Text(s.url).font(PX.Font.mono(10.5)).foregroundStyle(PX.Color.inkMuted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "plus.circle.fill").foregroundStyle(PX.Color.azimuth)
                            }
                            .padding(.horizontal, PX.Space.base)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if i < SourceStore.suggestions.count - 1 {
                            Divider().overlay(PX.Color.horizon).padding(.leading, 58)
                        }
                    }
                }
                .glassCard()
            }

            Button { newSourceURL = ""; addingSource = true } label: {
                Label("Ajouter une source", systemImage: "plus")
            }
            .buttonStyle(ProminentButtonStyle())
        }
    }

    private var addSourceSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PX.Space.base) {
                Text("Ajouter une source")
                    .font(PX.Font.display(22, .bold))
                    .foregroundStyle(PX.Color.ink)
                    .padding(.top, PX.Space.base)

                TextField("https://…", text: $newSourceURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .field("URL de la source", mono: true)

                Button {
                    let u = newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !u.isEmpty { store.add(u) }
                    addingSource = false
                } label: { Text("Ajouter") }
                .buttonStyle(ProminentButtonStyle(enabled: !newSourceURL.trimmingCharacters(in: .whitespaces).isEmpty))
                .disabled(newSourceURL.trimmingCharacters(in: .whitespaces).isEmpty)

                Text("Une source est un fichier JSON au format AltStore / SideStore. Colle son adresse ci-dessus.")
                    .font(PX.Font.body(12))
                    .foregroundStyle(PX.Color.inkMuted)
            }
            .padding(.horizontal, PX.Space.base)
        }
    }

    private var loadingCard: some View {
        HStack(spacing: PX.Space.snug) {
            ProgressView().tint(PX.Color.azimuth)
            Text("Lecture des sources…").font(PX.Font.body(13)).foregroundStyle(PX.Color.inkMuted)
            Spacer()
        }
        .padding(PX.Space.base)
        .glassCard()
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

    // MARK: - Helpers

    private func filtered(_ apps: [SourceApp]) -> [SourceApp] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return apps }
        return apps.filter {
            $0.name.lowercased().contains(q)
            || ($0.developerName ?? "").lowercased().contains(q)
            || ($0.subtitle ?? "").lowercased().contains(q)
            || $0.bundleIdentifier.lowercased().contains(q)
        }
    }

    private func shortURL(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }
}

// MARK: - Icône distante

/// Icône d'app tirée d'une source. `AsyncImage` avec repli propre : une source
/// hors-ligne ou une icône manquante ne laisse jamais un trou, juste la tuile.
private struct SourceIcon: View {
    let urlString: String?
    var tint: Color = PX.Color.azimuth
    var size: CGFloat = 48

    var body: some View {
        Group {
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.24), tint.opacity(0.12)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(Image(systemName: "app.dashed")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(tint.opacity(0.7)))
    }
}

// MARK: - Fiche d'app

/// Fiche détaillée d'une app d'une source, façon page produit App Store.
private struct SourceAppDetail: View {
    let app: SourceApp
    let onInstall: (_ url: String, _ name: String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PX.Space.base) {
                grabber

                HStack(spacing: PX.Space.base) {
                    SourceIcon(urlString: app.iconURL, tint: app.accent, size: 74)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(PX.Font.display(22, .bold))
                            .foregroundStyle(PX.Color.ink)
                            .lineLimit(2)
                        if let dev = app.developerName, !dev.isEmpty {
                            Text(dev).font(PX.Font.body(13)).foregroundStyle(PX.Color.inkMuted)
                        }
                        HStack(spacing: PX.Space.tight) {
                            if let v = app.resolvedVersion { Text("v\(v)").font(PX.Font.mono(11)) }
                            if let s = app.resolvedSizeText { Text(s).font(PX.Font.mono(11)) }
                        }
                        .foregroundStyle(PX.Color.inkFaint)
                    }
                    Spacer(minLength: 0)
                }

                if let sub = app.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(PX.Font.body(15, .medium))
                        .foregroundStyle(PX.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let desc = app.resolvedDescription, !desc.isEmpty {
                    VStack(alignment: .leading, spacing: PX.Space.tight) {
                        SectionLabel("Description")
                        Text(desc)
                            .font(PX.Font.body(13))
                            .foregroundStyle(PX.Color.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(PX.Space.base)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard()
                }

                VStack(alignment: .leading, spacing: PX.Space.tight) {
                    detailRow("Identifiant", app.bundleIdentifier, mono: true)
                    if let v = app.resolvedVersion { detailRow("Version", v, mono: true) }
                    if let d = app.resolvedDate { detailRow("Mise à jour", d) }
                }
                .padding(PX.Space.base)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()

                if let url = app.resolvedDownloadURL {
                    Button { onInstall(url, app.name) } label: {
                        Label("Envoyer à l'Installeur", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(ProminentButtonStyle())

                    Text("L'IPA s'ouvre dans l'Installeur, où tu choisis la signature (compte Apple ou certificat) avant de poser l'app.")
                        .font(PX.Font.body(11.5))
                        .foregroundStyle(PX.Color.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    banner("exclamationmark.triangle.fill", PX.Color.alert, "Pas de lien",
                           "Cette entrée ne fournit pas d'URL de téléchargement.")
                }
            }
            .padding(.horizontal, PX.Space.base)
            .padding(.bottom, PX.Space.loose)
        }
    }

    private var grabber: some View {
        Capsule().fill(PX.Color.horizon)
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.top, PX.Space.snug)
            .padding(.bottom, PX.Space.hair)
    }

    private func detailRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
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
    }
}
