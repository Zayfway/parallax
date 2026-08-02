import Foundation
import CoreLocation

/// Une trace GPX prête à être rejouée.
///
/// Deux cas à distinguer, et le second est le plus courant :
///
/// - trace **horodatée** (`<time>` sur chaque point) : on rejoue au tempo réel
///   enregistré ;
/// - trace **sans horodatage** — la majorité des fichiers issus d'un tracé
///   manuel : il faut synthétiser un tempo. On répartit alors le temps selon la
///   distance à vitesse constante, faute de quoi la lecture saute d'un point à
///   l'autre sans rapport avec la géométrie.
struct GPXTrack: Equatable {

    struct Point: Equatable {
        let coordinate: CLLocationCoordinate2D
        /// Secondes depuis le départ.
        let offset: TimeInterval

        static func == (a: Point, b: Point) -> Bool {
            a.offset == b.offset
                && a.coordinate.latitude == b.coordinate.latitude
                && a.coordinate.longitude == b.coordinate.longitude
        }
    }

    let name: String
    let points: [Point]

    var duration: TimeInterval { points.last?.offset ?? 0 }

    // MARK: - Lecture

    /// Position interpolée à `elapsed` secondes. `nil` une fois la trace finie.
    ///
    /// L'interpolation linéaire entre points voisins est ce qui fait la
    /// différence entre un déplacement crédible et une succession de sauts :
    /// un GPX de rando a typiquement un point toutes les 5–10 s, alors qu'on
    /// pousse un fix par seconde.
    func coordinate(atElapsed elapsed: TimeInterval) -> CLLocationCoordinate2D? {
        guard !points.isEmpty else { return nil }
        guard elapsed >= 0 else { return points[0].coordinate }
        guard elapsed < duration else { return nil }

        guard let idx = points.firstIndex(where: { $0.offset > elapsed }), idx > 0 else {
            return points[0].coordinate
        }

        let a = points[idx - 1], b = points[idx]
        let span = b.offset - a.offset
        guard span > 0 else { return a.coordinate }

        let t = (elapsed - a.offset) / span
        return CLLocationCoordinate2D(
            latitude: a.coordinate.latitude + (b.coordinate.latitude - a.coordinate.latitude) * t,
            longitude: a.coordinate.longitude + (b.coordinate.longitude - a.coordinate.longitude) * t
        )
    }

    // MARK: - Parsing

    enum ParseError: LocalizedError {
        case unreadable
        case noTrackPoints

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "Fichier GPX illisible."
            case .noTrackPoints:
                return "Aucun point de trace dans ce GPX."
            }
        }
    }

    /// `assumedSpeed` ne sert que pour les traces sans horodatage.
    static func parse(
        data: Data,
        name: String,
        assumedSpeed metersPerSecond: Double = 1.4
    ) throws -> GPXTrack {
        let parser = GPXParser()
        guard let raw = parser.parse(data), !raw.isEmpty else {
            throw parser.sawAnyXML ? ParseError.noTrackPoints : ParseError.unreadable
        }

        let points: [Point]
        if let first = raw.first?.time, raw.allSatisfy({ $0.time != nil }) {
            points = raw.map {
                Point(coordinate: $0.coordinate, offset: $0.time!.timeIntervalSince(first))
            }
        } else {
            // Tempo synthétique proportionnel à la distance.
            var offset: TimeInterval = 0
            var acc: [Point] = [Point(coordinate: raw[0].coordinate, offset: 0)]
            for i in 1..<raw.count {
                let d = CLLocation(raw[i - 1].coordinate).distance(from: CLLocation(raw[i].coordinate))
                offset += max(d / max(metersPerSecond, 0.1), 0.5)
                acc.append(Point(coordinate: raw[i].coordinate, offset: offset))
            }
            points = acc
        }

        return GPXTrack(name: name, points: points)
    }
}

// MARK: - XMLParser

private final class GPXParser: NSObject, XMLParserDelegate {

    struct Raw {
        let coordinate: CLLocationCoordinate2D
        var time: Date?
    }

    private(set) var sawAnyXML = false
    private var points: [Raw] = []
    private var pending: Raw?
    private var buffer = ""
    private var inTime = false

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func parse(_ data: Data) -> [Raw]? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { return points.isEmpty ? nil : points }
        return points
    }

    func parser(
        _ parser: XMLParser,
        didStartElement element: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attrs: [String: String]
    ) {
        sawAnyXML = true

        // `trkpt` d'abord, `rtept` en repli : certains exports ne produisent que
        // des routes. `wpt` est volontairement ignoré — ce sont des points
        // d'intérêt isolés, pas une trace, et les inclure produit des trajets
        // aberrants.
        switch element {
        case "trkpt", "rtept":
            guard let lat = attrs["lat"].flatMap(Double.init),
                  let lon = attrs["lon"].flatMap(Double.init) else { return }
            pending = Raw(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
        case "time":
            inTime = true
            buffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTime { buffer += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement element: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        switch element {
        case "time":
            inTime = false
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            pending?.time = iso.date(from: trimmed) ?? fallbackDate(trimmed)
        case "trkpt", "rtept":
            if let p = pending { points.append(p) }
            pending = nil
        default:
            break
        }
    }

    /// Beaucoup de GPX omettent les fractions de seconde.
    private func fallbackDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Partagé avec `RoutePlanner` : les deux calculent des longueurs de trace.
extension CLLocation {
    convenience init(_ c: CLLocationCoordinate2D) {
        self.init(latitude: c.latitude, longitude: c.longitude)
    }
}
