import CoreLocation
import Foundation

struct TrailRoute {
    static let name = "Whistler 50K"
    static let edition = "2026 · Whistler, BC"
    static let officialAscent = 2_942
    static let source = URL(string: "https://whistler.utmb.world/races/50k")!

    let fileURL: URL
    let path: Route3DPath

    var kilometers: String { (path.distanceMeters / 1_000).formatted(.number.precision(.fractionLength(2))) }

    init() throws {
        guard let fileURL = Bundle.main.url(forResource: "Whistler50K", withExtension: "gpx"),
              let parser = XMLParser(contentsOf: fileURL) else {
            throw RouteError.missingFile
        }

        let loader = GPXTrackReader()
        parser.delegate = loader
        guard parser.parse(), loader.points.count > 1 else {
            throw RouteError.invalidTrack
        }

        self.path = try Route3DPath(locations: loader.points)
        self.fileURL = fileURL
    }

    private enum RouteError: Error {
        case missingFile
        case invalidTrack
    }
}

private final class GPXTrackReader: NSObject, XMLParserDelegate {
    private(set) var points: [CLLocation] = []
    private var coordinate: CLLocationCoordinate2D?
    private var elevation: Double?
    private var elevationText: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch elementName {
        case "trkpt":
            elevation = nil
            if let latitude = attributes["lat"].flatMap(Double.init),
               let longitude = attributes["lon"].flatMap(Double.init) {
                let point = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                coordinate = CLLocationCoordinate2DIsValid(point) ? point : nil
            }
        case "ele" where coordinate != nil:
            elevationText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        elevationText?.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        switch elementName {
        case "ele":
            elevation = elevationText.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            elevationText = nil
        case "trkpt":
            if let coordinate, let elevation, elevation.isFinite {
                points.append(CLLocation(
                    coordinate: coordinate,
                    altitude: elevation,
                    horizontalAccuracy: 0,
                    verticalAccuracy: 0,
                    timestamp: .distantPast
                ))
            }
            coordinate = nil
        default:
            break
        }
    }
}
