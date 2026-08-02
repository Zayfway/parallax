import Foundation
import CoreLocation

/// Lieux enregistrés — les « fiches ».
///
/// Une position qu'on veut retrouver ne doit pas se re-saisir à la main. On
/// garde donc un petit carnet persisté : un nom, des coordonnées, une date.
/// Rien de plus — c'est un carnet d'adresses, pas une base de données, et il
/// tient entièrement dans `UserDefaults`.
@MainActor
final class FavoritesStore: ObservableObject {

    struct Place: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        let latitude: Double
        let longitude: Double
        let createdAt: Date

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        /// En mono : ce sont des coordonnées, donc une valeur machine.
        var coordinateLabel: String {
            String(format: "%+.5f · %+.5f", latitude, longitude)
        }
    }

    @Published private(set) var places: [Place] = []

    private let key = "savedPlaces.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Mutations

    /// Le plus récent en tête : c'est celui qu'on vient de poser, donc le plus
    /// probable à rappeler tout de suite.
    func add(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = Place(
            id: UUID(),
            name: trimmed.isEmpty ? Self.autoName(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            createdAt: .now
        )
        places.insert(place, at: 0)
        persist()
    }

    func remove(_ place: Place) {
        places.removeAll { $0.id == place.id }
        persist()
    }

    func rename(_ place: Place, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = places.firstIndex(where: { $0.id == place.id }) else { return }
        places[index].name = trimmed
        persist()
    }

    /// Vrai si un lieu très proche est déjà enregistré. Évite les doublons
    /// quand on ré-appuie sur « enregistrer » au même endroit.
    func contains(_ coordinate: CLLocationCoordinate2D, within meters: Double = 25) -> Bool {
        let here = CLLocation(coordinate)
        return places.contains { CLLocation($0.coordinate).distance(from: here) < meters }
    }

    // MARK: - Persistance

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Place].self, from: data) else { return }
        places = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(places) else { return }
        defaults.set(data, forKey: key)
    }

    /// Faute de nom, les coordonnées font un repère lisible et unique.
    private static func autoName(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.4f, %.4f", c.latitude, c.longitude)
    }
}
