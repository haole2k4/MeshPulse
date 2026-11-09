import Foundation

/// Pure geodesic math for offline GPS & compass peer finding (AirTag-style Precision Finding).
public enum ProximityMath: Sendable {
    public static let earthMeanRadiusMeters: Double = 6_371_000.0

    /// Great-circle Haversine distance in meters between two GNSS coordinates.
    public static func haversineDistanceMeters(
        from origin: GeoCoordinate,
        to target: GeoCoordinate
    ) -> Double {
        let lat1 = origin.latitude * .pi / 180.0
        let lon1 = origin.longitude * .pi / 180.0
        let lat2 = target.latitude * .pi / 180.0
        let lon2 = target.longitude * .pi / 180.0

        let dLat = lat2 - lat1
        let dLon = lon2 - lon1

        let sinHalfLat = sin(dLat / 2.0)
        let sinHalfLon = sin(dLon / 2.0)
        let a =
            sinHalfLat * sinHalfLat
            + cos(lat1) * cos(lat2) * sinHalfLon * sinHalfLon
        let clampedA = min(1.0, max(0.0, a))
        let c = 2.0 * atan2(sqrt(clampedA), sqrt(1.0 - clampedA))
        return earthMeanRadiusMeters * c
    }

    /// Initial forward azimuth (bearing) in degrees `[0, 360)` from `origin` to `target`
    /// where `0°` = True North, `90°` = East, `180°` = South, `270°` = West.
    public static func bearingDegrees(
        from origin: GeoCoordinate,
        to target: GeoCoordinate
    ) -> Double {
        let lat1 = origin.latitude * .pi / 180.0
        let lon1 = origin.longitude * .pi / 180.0
        let lat2 = target.latitude * .pi / 180.0
        let lon2 = target.longitude * .pi / 180.0

        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radians = atan2(y, x)
        let degrees = radians * 180.0 / .pi
        let normalized = (degrees + 360.0).truncatingRemainder(dividingBy: 360.0)
        return normalized
    }

    /// Relative clockwise rotation angle in degrees `(-180, +180]` for the UI arrow
    /// given the target's true `bearingDegrees` and the phone's current compass `deviceHeadingDegrees`.
    public static func relativeArrowAngleDegrees(
        bearing: Double,
        deviceHeading: Double
    ) -> Double {
        var delta = (bearing - deviceHeading).truncatingRemainder(dividingBy: 360.0)
        if delta > 180.0 {
            delta -= 360.0
        } else if delta <= -180.0 {
            delta += 360.0
        }
        return delta
    }

    /// Vietnamese 8-point cardinal compass direction label (e.g. `"Đông Bắc"`).
    public static func cardinalDirectionVN(forBearing degrees: Double) -> String {
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360.0)) + 360.0)
            .truncatingRemainder(dividingBy: 360.0)
        let directions = [
            "Bắc",
            "Đông Bắc",
            "Đông",
            "Đông Nam",
            "Nam",
            "Tây Nam",
            "Tây",
            "Tây Bắc",
        ]
        let index = Int(((normalized + 22.5) / 45.0).rounded(.down)) % 8
        return directions[index]
    }

    /// Human-readable tactical distance + bearing string (e.g. `"Cách 42m • Hướng Đông Bắc"`).
    public static func formattedProximitySummary(
        from origin: GeoCoordinate,
        to target: GeoCoordinate
    ) -> String {
        let dist = haversineDistanceMeters(from: origin, to: target)
        let bearing = bearingDegrees(from: origin, to: target)
        let cardinal = cardinalDirectionVN(forBearing: bearing)
        if dist < 1000 {
            return "Cách \(Int(dist.rounded()))m • Hướng \(cardinal)"
        } else {
            let km = (dist / 100.0).rounded() / 10.0
            return "Cách \(km)km • Hướng \(cardinal)"
        }
    }
}
