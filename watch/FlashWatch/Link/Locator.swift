import CoreLocation
import Foundation

/// Where the watch is, told to Flash only while "Let Flash see my
/// location" is on. Off, nothing is asked of Core Location and Flash is
/// told to forget the last place it had.
@MainActor
final class Locator: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Locator()

    /// Why the watch has no place to give, for Settings to show.
    @Published private(set) var problem: String?

    private let manager = CLLocationManager()
    private weak var flash: Flash?
    private var lastSent: Date?
    /// How often a new place goes to Flash, at most.
    private static let every: TimeInterval = 5 * 60

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    static var on: Bool {
        UserDefaults.standard.bool(forKey: Prefs.shareLocation)
    }

    /// Share now if the switch is on; never asks permission when off.
    func update(_ flash: Flash, force: Bool = false) {
        self.flash = flash
        guard Self.on else { return }
        if !force, let lastSent, Date().timeIntervalSince(lastSent) < Self.every { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            problem = "Allow Location for Flash in the watch's Settings, under Privacy."
        default:
            problem = nil
            manager.requestLocation()
        }
    }

    /// The switch went off: stop, and have Flash forget the place.
    func stop(_ flash: Flash) {
        self.flash = flash
        lastSent = nil
        problem = nil
        manager.stopUpdatingLocation()
        Task { try? await flash.run { try await $0.command("location", arg: "off") } }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard Self.on, let flash = self.flash else { return }
            self.update(flash, force: true)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let place = locations.last else { return }
        let fix: [String: Any] = [
            "lat": place.coordinate.latitude,
            "lon": place.coordinate.longitude,
            "accuracy": place.horizontalAccuracy,
        ]
        Task { @MainActor in
            // Switched off while the fix was on its way: drop it.
            guard Self.on, let flash = self.flash else { return }
            do {
                _ = try await flash.run { try await $0.command("location", fix) }
                self.lastSent = Date()
                self.problem = nil
            } catch {
                self.problem = error.localizedDescription
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in
            self.problem = "The watch couldn't find where it is just now."
        }
    }
}
