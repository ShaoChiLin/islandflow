import CoreLocation

/// 到站驗證的定位輔助。只取一次位置，拿不到就回 nil，由畫面決定要不要走人工示範模式。
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentLocation() async -> CLLocation? {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            try? await Task.sleep(for: .seconds(1.5))
        }
        guard [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) else { return nil }
        return await withCheckedContinuation { c in
            continuation = c
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let loc = locations.last
        Task { @MainActor in self.finish(loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    private func finish(_ loc: CLLocation?) {
        continuation?.resume(returning: loc)
        continuation = nil
    }
}
