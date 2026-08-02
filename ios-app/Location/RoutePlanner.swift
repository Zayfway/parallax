import CoreLocation
import Foundation
import MapKit

// ═══════════════════════════════════════════════════════════════════════════
// ITINÉRAIRES
//
// Un trajet simulé n'est pas une machinerie nouvelle : c'est une `GPXTrack`
// qu'on calcule au lieu de la lire. Le moteur sait déjà jouer une trace point
// par point, en interpolant entre deux horodatages — il suffit donc de lui en
// fabriquer une, et tout le chemin existant fonctionne sans y toucher.
//
// ── LE RÉALISME VIENT DU PROFIL ───────────────────────────────────────────
//
// Voiture et marche passent par `MKDirections`, donc suivent les routes et les
// chemins réels ; leur durée est celle qu'Apple estime, ce qui donne des
// ralentissements en ville et des vitesses d'autoroute sans qu'on ait rien à
// modéliser. L'avion ne suit rien : c'est une orthodromie, la ligne la plus
// courte sur la sphère, celle que suivent réellement les vols long-courriers.
//
// Le multiplicateur de vitesse ne déforme que le temps, jamais la trajectoire.
// Un trajet accéléré reste crédible ; un trajet dont on aurait tiré les points
// ne l'est pas.
// ═══════════════════════════════════════════════════════════════════════════

enum RouteProfile: String, CaseIterable, Identifiable {
    case walking = "Marche"
    case cycling = "Vélo"
    case driving = "Voiture"
    case flying  = "Avion"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .walking: "figure.walk"
        case .cycling: "bicycle"
        case .driving: "car.fill"
        case .flying:  "airplane"
        }
    }

    /// Vitesse de croisière en km/h, utilisée quand aucune durée n'est estimée.
    /// Le vélo n'existe pas chez `MKDirections`, l'avion non plus.
    var cruiseKPH: Double {
        switch self {
        case .walking: 4.8
        case .cycling: 19
        case .driving: 50
        case .flying:  880
        }
    }

    /// `nil` quand le profil ne suit aucune route et doit être tracé à la main.
    var transportType: MKDirectionsTransportType? {
        switch self {
        case .walking:          .walking
        case .driving:          .automobile
        // Le vélo emprunte les chemins piétons faute de mieux — c'est plus
        // juste que de le faire rouler sur l'autoroute.
        case .cycling:          .walking
        case .flying:           nil
        }
    }

    var followsRoads: Bool { transportType != nil }
}

/// Calcule un trajet et le rend sous forme de trace jouable.
enum RoutePlanner {

    enum PlanningError: LocalizedError {
        case noRoute
        case tooShort
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noRoute:
                "Aucun itinéraire trouvé entre ces deux points. Essaie un autre profil — l'avion passe partout."
            case .tooShort:
                "Les deux points sont trop proches pour faire un trajet."
            case .failed(let why): why
            }
        }
    }

    struct Plan {
        let track: GPXTrack
        /// Tracé affiché sur la carte, avant même de lancer le trajet.
        let polyline: [CLLocationCoordinate2D]
        let distance: CLLocationDistance
        /// Durée après application du multiplicateur.
        let duration: TimeInterval
        let profile: RouteProfile

        var distanceLabel: String {
            distance >= 1000
                ? String(format: "%.1f km", distance / 1000)
                : String(format: "%.0f m", distance)
        }

        var durationLabel: String {
            let total = Int(duration.rounded())
            if total >= 3600 { return "\(total / 3600) h \(String(format: "%02d", (total % 3600) / 60))" }
            if total >= 60 { return "\(total / 60) min" }
            return "\(total) s"
        }
    }

    /// `speedFactor` accélère ou ralentit le temps sans toucher au tracé.
    static func plan(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        profile: RouteProfile,
        speedFactor: Double = 1
    ) async throws -> Plan {
        let direct = CLLocation(start).distance(from: CLLocation(end))
        guard direct > 25 else { throw PlanningError.tooShort }

        let (coordinates, estimated): ([CLLocationCoordinate2D], TimeInterval?)

        if let transport = profile.transportType {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
            request.transportType = transport

            do {
                let response = try await MKDirections(request: request).calculate()
                guard let route = response.routes.first else { throw PlanningError.noRoute }
                coordinates = route.polyline.coordinates
                // Le vélo emprunte le tracé piéton mais garde sa propre vitesse :
                // reprendre la durée de marche le ferait avancer au pas.
                estimated = profile == .cycling ? nil : route.expectedTravelTime
            } catch let error as PlanningError {
                throw error
            } catch {
                throw PlanningError.failed(
                    "Calcul d'itinéraire impossible : \(error.localizedDescription)"
                )
            }
        } else {
            coordinates = greatCircle(from: start, to: end)
            estimated = nil
        }

        guard coordinates.count >= 2 else { throw PlanningError.noRoute }

        let distance = pathLength(coordinates)
        // Sans estimation, on déduit la durée de la vitesse de croisière.
        let base = estimated ?? (distance / (profile.cruiseKPH * 1000 / 3600))
        let duration = max(base / max(speedFactor, 0.05), 1)

        return Plan(
            track: track(along: coordinates, distance: distance,
                         duration: duration, name: profile.rawValue),
            polyline: coordinates,
            distance: distance,
            duration: duration,
            profile: profile
        )
    }

    // MARK: - Fabrication de la trace

    /// Répartit les horodatages **proportionnellement à la distance**, pas au
    /// nombre de points. `MKDirections` densifie les virages et espace les
    /// lignes droites ; par index, on ralentirait dans chaque rond-point et on
    /// filerait sur les portions droites.
    private static func track(
        along coordinates: [CLLocationCoordinate2D],
        distance: CLLocationDistance,
        duration: TimeInterval,
        name: String
    ) -> GPXTrack {
        guard distance > 0 else {
            return GPXTrack(name: name, points: [.init(coordinate: coordinates[0], offset: 0)])
        }

        var points: [GPXTrack.Point] = [.init(coordinate: coordinates[0], offset: 0)]
        var travelled: CLLocationDistance = 0

        for index in 1..<coordinates.count {
            travelled += CLLocation(coordinates[index - 1])
                .distance(from: CLLocation(coordinates[index]))
            points.append(.init(
                coordinate: coordinates[index],
                offset: duration * (travelled / distance)
            ))
        }
        return GPXTrack(name: name, points: points)
    }

    private static func pathLength(_ coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard coordinates.count >= 2 else { return 0 }
        return (1..<coordinates.count).reduce(0) { total, index in
            total + CLLocation(coordinates[index - 1]).distance(from: CLLocation(coordinates[index]))
        }
    }

    // MARK: - Orthodromie

    /// Interpolation sphérique entre deux points.
    ///
    /// Une interpolation linéaire en latitude/longitude donnerait une ligne
    /// droite sur une carte plate, qui n'est pas le chemin le plus court sur
    /// une sphère : un Paris–Tokyo passerait par la Sibérie du sud au lieu du
    /// pôle. Le mensonge se verrait à la trace.
    private static func greatCircle(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        segments: Int = 220
    ) -> [CLLocationCoordinate2D] {
        let φ1 = start.latitude * .pi / 180, λ1 = start.longitude * .pi / 180
        let φ2 = end.latitude * .pi / 180,   λ2 = end.longitude * .pi / 180

        let δ = 2 * asin(min(1, sqrt(
            pow(sin((φ2 - φ1) / 2), 2)
            + cos(φ1) * cos(φ2) * pow(sin((λ2 - λ1) / 2), 2)
        )))
        guard δ > 1e-9 else { return [start, end] }

        return (0...segments).map { step in
            let f = Double(step) / Double(segments)
            let a = sin((1 - f) * δ) / sin(δ)
            let b = sin(f * δ) / sin(δ)

            let x = a * cos(φ1) * cos(λ1) + b * cos(φ2) * cos(λ2)
            let y = a * cos(φ1) * sin(λ1) + b * cos(φ2) * sin(λ2)
            let z = a * sin(φ1) + b * sin(φ2)

            return CLLocationCoordinate2D(
                latitude: atan2(z, sqrt(x * x + y * y)) * 180 / .pi,
                longitude: atan2(y, x) * 180 / .pi
            )
        }
    }
}

extension MKPolyline {
    /// Les coordonnées d'une polyligne, que MapKit n'expose qu'en tampon brut.
    var coordinates: [CLLocationCoordinate2D] {
        var result = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid, count: pointCount
        )
        getCoordinates(&result, range: NSRange(location: 0, length: pointCount))
        return result
    }
}
