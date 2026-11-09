#if canImport(CoreLocation) && canImport(SwiftUI)
import CoreLocation
import Foundation
import MeshCore

/// Offline GNSS coordinate provider (`CLLocationManager` hardware GPS/GLONASS/Galileo)
/// with bounded authorization & fix timeouts so SOS and chat dispatch never hang indoors.
@MainActor
public final class LocationProvider: NSObject, OfflineLocationProviding, CLLocationManagerDelegate {
    private static let freshCacheMaxAgeSeconds: TimeInterval = 90.0
    private static let authTimeoutMilliseconds = 4_000
    private static let fixTimeoutMilliseconds = 2_500

    private let manager = CLLocationManager()
    private var authWaiters: [UUID: CheckedContinuation<CLAuthorizationStatus, Never>] = [:]
    private var locationWaiters: [UUID: CheckedContinuation<GeoCoordinate?, Never>] = [:]
    public private(set) var latestHeadingDegrees: Double = 0.0
    public var onHeadingUpdate: ((Double) -> Void)?

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.headingFilter = 2.0
    }

    public func startHeadingUpdates() {
        #if os(iOS)
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
        #endif
    }

    public func stopHeadingUpdates() {
        #if os(iOS)
        if CLLocationManager.headingAvailable() {
            manager.stopUpdatingHeading()
        }
        #endif
    }

    public func currentCoordinate() async -> GeoCoordinate? {
        var status = manager.authorizationStatus
        if status == .denied || status == .restricted {
            return nil
        }

        if status == .notDetermined {
            status = await requestAuthorizationWithTimeout()
        }

        guard isAuthorized(status) else {
            return nil
        }

        if let fresh = recentCachedCoordinate(maxAge: Self.freshCacheMaxAgeSeconds) {
            return fresh
        }

        return await requestSingleLocationWithTimeout()
    }

    // MARK: - Authorization & Single-Fix Bounded Waiters

    private func requestAuthorizationWithTimeout() async -> CLAuthorizationStatus {
        let waiterID = UUID()
        let wasEmpty = authWaiters.isEmpty

        return await withCheckedContinuation { continuation in
            authWaiters[waiterID] = continuation
            if wasEmpty {
                manager.requestWhenInUseAuthorization()
            }

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.authTimeoutMilliseconds))
                guard let self, let pending = self.authWaiters.removeValue(forKey: waiterID) else {
                    return
                }
                pending.resume(returning: self.manager.authorizationStatus)
            }
        }
    }

    private func requestSingleLocationWithTimeout() async -> GeoCoordinate? {
        let waiterID = UUID()
        let shouldStartHardwareRequest = locationWaiters.isEmpty

        return await withCheckedContinuation { continuation in
            locationWaiters[waiterID] = continuation
            if shouldStartHardwareRequest {
                manager.requestLocation()
            }

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.fixTimeoutMilliseconds))
                guard let self, let pending = self.locationWaiters.removeValue(forKey: waiterID) else {
                    return
                }
                pending.resume(returning: self.bestAvailableCachedCoordinate())
            }
        }
    }

    private func recentCachedCoordinate(maxAge: TimeInterval) -> GeoCoordinate? {
        guard let location = manager.location,
              location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < maxAge
        else {
            return nil
        }
        return Self.makeGeoCoordinate(from: location)
    }

    private func bestAvailableCachedCoordinate() -> GeoCoordinate? {
        guard let location = manager.location, location.horizontalAccuracy >= 0 else {
            return nil
        }
        return Self.makeGeoCoordinate(from: location)
    }

    nonisolated private static func makeGeoCoordinate(from loc: CLLocation) -> GeoCoordinate {
        let alt: Double? = loc.verticalAccuracy >= 0 ? loc.altitude : nil
        let spd: Double? = loc.speed >= 0 ? loc.speed : nil
        return GeoCoordinate(
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            accuracyMeters: loc.horizontalAccuracy,
            altitudeMeters: alt,
            speedMetersPerSecond: spd
        )
    }

    private func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(iOS)
        return status == .authorizedWhenInUse || status == .authorizedAlways
        #else
        return status == .authorizedAlways
        #endif
    }

    private func resolveAuthWaiters(with status: CLAuthorizationStatus) {
        guard status != .notDetermined, !authWaiters.isEmpty else { return }
        let waiters = authWaiters
        authWaiters.removeAll()
        for continuation in waiters.values {
            continuation.resume(returning: status)
        }
    }

    private func resolveLocationWaiters(with coordinate: GeoCoordinate?) {
        guard !locationWaiters.isEmpty else { return }
        let waiters = locationWaiters
        locationWaiters.removeAll()
        let resolved = coordinate ?? bestAvailableCachedCoordinate()
        for continuation in waiters.values {
            continuation.resume(returning: resolved)
        }
    }

    // MARK: - CLLocationManagerDelegate (Nonisolated Objective-C Witnesses)

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.resolveAuthWaiters(with: status)
        }
    }

    nonisolated public func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let validCoord = locations
            .last(where: { $0.horizontalAccuracy >= 0 })
            .map { Self.makeGeoCoordinate(from: $0) }

        Task { @MainActor [weak self] in
            self?.resolveLocationWaiters(with: validCoord)
        }
    }

    #if os(iOS)
    nonisolated public func locationManager(
        _ manager: CLLocationManager,
        didUpdateHeading newHeading: CLHeading
    ) {
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard heading >= 0 else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.latestHeadingDegrees = heading
            self.onHeadingUpdate?(heading)
        }
    }
    #endif

    nonisolated public func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: any Error
    ) {
        Task { @MainActor [weak self] in
            self?.resolveLocationWaiters(with: nil)
        }
    }
}
#endif
