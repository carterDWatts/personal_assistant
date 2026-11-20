import Foundation
import MapKit
import CoreLocation
import UserNotifications

@MainActor final class Places: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = Places()
    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<CLLocation, Error>?
    private var recordedReceipts = Set<String>()
    private var recentlyScheduled: [String: Date] = [:]
    private var timeout: Task<Void, Never>?
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyHundredMeters }

    func run(_ args: [String: Any]) async -> [String: Any] {
        do {
            switch args["action"] as? String {
            case "location_reminder":
                #if os(iOS)
                return try await schedule(args)
                #else
                throw failure("Location reminders need your iPhone. Open this conversation there to set one.")
                #endif
            case "location":
                let location = try await locate()
                return ["latitude": location.coordinate.latitude, "longitude": location.coordinate.longitude,
                        "accuracy_meters": location.horizontalAccuracy, "observed_at": location.timestamp.ISO8601Format()]
            case "places":
                guard let query = args["query"] as? String, !query.isEmpty else { throw failure("Specify a place to search for.") }
                let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
                if let lat = args["latitude"] as? Double, let lon = args["longitude"] as? Double {
                    request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon), latitudinalMeters: 15000, longitudinalMeters: 15000)
                }
                let response = try await MKLocalSearch(request: request).start()
                return ["places": response.mapItems.prefix(8).map(place), "fetched_at": Date().ISO8601Format(),
                        "note": "Apple Maps results. Hours, live availability and reviews are not included."]
            case "route":
                guard let origin = args["origin"] as? String, let destination = args["destination"] as? String else {
                    throw failure("Specify both origin and destination; do not assume the phone's location.")
                }
                let start = try await resolve(origin), end = try await resolve(destination)
                let request = MKDirections.Request(); request.source = start; request.destination = end
                request.transportType = args["mode"] as? String == "walking" ? .walking : .automobile
                let response = try await MKDirections(request: request).calculate()
                guard let route = response.routes.first else { throw failure("No route is available.") }
                var url = URLComponents(string: "https://maps.apple.com/")!
                url.queryItems = [URLQueryItem(name: "saddr", value: coordinate(start)), URLQueryItem(name: "daddr", value: coordinate(end)), URLQueryItem(name: "dirflg", value: request.transportType == .walking ? "w" : "d")]
                return ["origin": place(start), "destination": place(end), "distance_meters": route.distance,
                        "expected_seconds": route.expectedTravelTime, "maps_url": url.url!.absoluteString,
                        "fetched_at": Date().ISO8601Format(), "note": "Travel estimate at fetch time. Recheck before departure."]
            default: throw failure("Unsupported maps request.")
            }
        } catch { return ["error": error.localizedDescription] }
    }

    #if os(iOS)
    private func schedule(_ args: [String: Any]) async throws -> [String: Any] {
        guard let id = args["id"] as? String, let version = args["version"] as? Int,
              let lat = args["latitude"] as? Double, let lon = args["longitude"] as? Double,
              let radius = args["radius"] as? Double else { throw failure("Invalid location reminder.") }
        if manager.authorizationStatus == .notDetermined { _ = try await locate() }
        if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
        guard manager.authorizationStatus == .authorizedAlways else {
            return ["scheduled": false, "note": "Set Bunny Man's location permission to Always in iPhone Settings, then ask me to try again."]
        }
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert, .sound]) else {
            return ["scheduled": false, "note": "Allow notifications in Settings to use location reminders."]
        }
        let pending = await center.pendingNotificationRequests()
        let key = "place-reminder-" + id
        guard pending.filter({ $0.identifier.hasPrefix("place-reminder-") && $0.identifier != key }).count < 15 else {
            throw failure("There are already 15 location reminders on this phone. Complete or cancel one first.")
        }
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self), manager.maximumRegionMonitoringDistance > 0 else {
            throw failure("Location reminders are not available on this device.")
        }
        let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon), radius: min(radius, manager.maximumRegionMonitoringDistance), identifier: key)
        region.notifyOnEntry = args["event"] as? String == "arrival"; region.notifyOnExit = !region.notifyOnEntry
        let content = UNMutableNotificationContent(); content.title = AssistantIdentity.name
        content.body = args["title"] as? String ?? "Reminder"; content.categoryIdentifier = "REMINDER"; content.sound = .default
        content.userInfo = ["reminder_id": id, "version": version, "location_reminder": true]
        try await center.add(UNNotificationRequest(identifier: key, content: content, trigger: UNLocationNotificationTrigger(region: region, repeats: false)))
        recentlyScheduled[key] = Date()
        return ["scheduled": true, "device_id": Account.shared.deviceID]
    }

    func sync(_ rows: [[String: Any]], delivered: ([String: Any]) async throws -> Void) async {
        let center = UNUserNotificationCenter.current()
        let valid = Dictionary(rows.compactMap { row -> (String, Int)? in
            guard let id = row["id"] as? String, let version = row["version"] as? Int else { return nil }
            return ("place-reminder-" + id, version)
        }, uniquingKeysWith: { _, new in new })
        let shown = await center.deliveredNotifications()
        for notice in shown where notice.request.content.userInfo["location_reminder"] as? Bool == true {
            let info = notice.request.content.userInfo
            if let id = info["reminder_id"] as? String, let version = info["version"] as? Int {
                let key = id + ":" + String(version)
                guard !recordedReceipts.contains(key) else { continue }
                do {
                    try await delivered(["action":"delivered", "id":id, "version":version])
                    recordedReceipts.insert(key)
                }
                catch { continue }
            }
        }
        let pending = await center.pendingNotificationRequests()
        let scheduled = Set(pending.map { $0.identifier })
        // A dismissed or removed OS notification must not suppress follow-up forever.
        // This receipt resumes follow-up; it never claims the task was completed.
        for row in rows {
            guard let id = row["id"] as? String, let version = row["version"] as? Int else { continue }
            let key = "place-reminder-" + id, receipt = id + ":" + String(version)
            guard !scheduled.contains(key), !recordedReceipts.contains(receipt),
                  Date().timeIntervalSince(recentlyScheduled[key] ?? .distantPast) > 30 else { continue }
            do {
                try await delivered(["action":"unscheduled", "id":id, "version":version])
                recordedReceipts.insert(receipt)
            } catch { continue }
        }
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { item in
            item.identifier.hasPrefix("place-reminder-") && Date().timeIntervalSince(recentlyScheduled[item.identifier] ?? .distantPast) > 30 && valid[item.identifier] != item.content.userInfo["version"] as? Int
        }.map { $0.identifier })
    }

    #endif

    private func coordinate(_ item: MKMapItem) -> String { "\(item.placemark.coordinate.latitude),\(item.placemark.coordinate.longitude)" }
    private func place(_ item: MKMapItem) -> [String: Any] {
        var url = URLComponents(string: "https://maps.apple.com/")!
        url.queryItems = [URLQueryItem(name: "ll", value: coordinate(item)), URLQueryItem(name: "q", value: item.name ?? "Place")]
        var result: [String: Any] = ["name": item.name ?? "Place", "address": item.placemark.title ?? "", "latitude": item.placemark.coordinate.latitude,
                                    "longitude": item.placemark.coordinate.longitude, "maps_url": url.url!.absoluteString]
        if let website = item.url { result["website"] = website.absoluteString }
        if let phone = item.phoneNumber { result["phone"] = phone }
        return result
    }
    private func resolve(_ query: String) async throws -> MKMapItem {
        let parts = query.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]), (-90...90).contains(lat), (-180...180).contains(lon) {
            return MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)))
        }
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
        let response = try await MKLocalSearch(request: request).start()
        guard response.mapItems.count == 1, let item = response.mapItems.first else {
            throw failure("That location is ambiguous. Search places first and use the selected coordinates for directions.")
        }
        return item
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "Places", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func locate() async throws -> CLLocation {
        guard pending == nil else { throw failure("Another location request is running.") }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                finish(.failure(failure("Location timed out. You can give me a city or address instead.")))
            }
            authorize()
        }
    }
    private func authorize() {
        guard pending != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            #if os(iOS)
            manager.requestWhenInUseAuthorization()
            #else
            manager.requestAlwaysAuthorization()
            #endif
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        default: finish(.failure(failure("Location access is off. Enable it in Settings or provide an address.")))
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { authorize() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0, abs(location.timestamp.timeIntervalSinceNow) < 60 else { return }
        finish(.success(location))
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { finish(.failure(error)) }
    private func finish(_ result: Result<CLLocation, Error>) {
        timeout?.cancel(); timeout = nil
        let continuation = pending; pending = nil
        continuation?.resume(with: result)
    }
}
