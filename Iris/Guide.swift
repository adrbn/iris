import CoreLocation
import Foundation

/// Audio guide: where am I (GPS) + what's around (French Wikipedia geosearch) → a prompt the
/// brain answers with the glasses' photo. Same idea as Cicerone, without its servers or keys.
@MainActor
final class Guide: NSObject, CLLocationManagerDelegate {
    private let location = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    struct Place { let title: String; let extract: String; let meters: Int? }

    /// The question to send with the photo, grounded in what Wikipedia knows within 600 m.
    func prompt() async -> String {
        guard let here = await locate() else {
            return "Je n'ai pas de position GPS. Décris ce que je regarde comme un guide touristique, à l'oral, en 4 à 6 phrases."
        }
        let places = (try? await Self.nearby(here)) ?? []
        Log.line("guide: \(places.count) lieux autour de \(here.coordinate.latitude),\(here.coordinate.longitude)")
        let list = places.map { "- \($0.title)\($0.meters.map { " (à \($0) m)" } ?? "") : \($0.extract)" }.joined(separator: "\n")
        return """
        Tu es mon guide touristique. Lieux référencés autour de moi (Wikipédia) :
        \(list.isEmpty ? "aucun" : list)
        L'image montre ce que je regarde. Dis-moi ce que c'est, en t'appuyant sur ces lieux si l'un correspond, \
        puis raconte une ou deux choses marquantes. 4 à 6 phrases, à l'oral, sans liste. N'invente rien : \
        si tu n'es pas sûr de ce que je regarde, dis-le.
        """
    }

    private func locate() async -> CLLocation? {
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        if let recent = location.location, recent.timestamp.timeIntervalSinceNow > -60 { return recent }
        waiting?.resume(returning: nil)
        return await withCheckedContinuation { done in
            waiting = done
            location.requestLocation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.waiting?.resume(returning: self?.location.location)
                self?.waiting = nil
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { waiting?.resume(returning: locations.last); waiting = nil }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { Log.line("guide gps \(error.localizedDescription)") }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {}

    static func nearby(_ here: CLLocation) async throws -> [Place] {
        var c = URLComponents(string: "https://fr.wikipedia.org/w/api.php")!
        c.queryItems = [
            "action": "query", "generator": "geosearch", "ggsradius": "600", "ggslimit": "6",
            "ggscoord": "\(here.coordinate.latitude)|\(here.coordinate.longitude)",
            "prop": "extracts|coordinates", "exintro": "1", "explaintext": "1", "exlimit": "6", "exchars": "500",
            "format": "json", "formatversion": "2",
        ].map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: c.url!, timeoutInterval: 8)
        request.setValue("Iris/0.1 (app perso)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try parse(data, from: here)
    }

    struct Response: Decodable {
        struct Query: Decodable { let pages: [Page] }
        struct Page: Decodable { let title: String; let extract: String?; let coordinates: [Coord]? }
        struct Coord: Decodable { let lat: Double; let lon: Double }
        let query: Query?
    }

    static func parse(_ data: Data, from here: CLLocation) throws -> [Place] {
        let pages = try JSONDecoder().decode(Response.self, from: data).query?.pages ?? []
        return pages.map { page in
            let meters = page.coordinates?.first.map { Int(here.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon))) }
            return Place(title: page.title, extract: page.extract ?? "", meters: meters)
        }
        .sorted { ($0.meters ?? .max) < ($1.meters ?? .max) }
    }
}
