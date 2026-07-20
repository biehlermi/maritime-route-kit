import Foundation
import MapKit

enum MaritimeGeometry {
  static let earthRadiusMeters = 6_371_008.8

  static func isValid(_ coordinate: MaritimeCoordinate) -> Bool {
    coordinate.latitude.isFinite
      && coordinate.longitude.isFinite
      && (-90...90).contains(coordinate.latitude)
      && (-180...180).contains(coordinate.longitude)
  }

  static func distance(_ first: MaritimeCoordinate, _ second: MaritimeCoordinate) -> Double {
    let lat1 = first.latitude * .pi / 180
    let lat2 = second.latitude * .pi / 180
    let deltaLat = (second.latitude - first.latitude) * .pi / 180
    let deltaLon = wrappedLongitudeDelta(from: first.longitude, to: second.longitude) * .pi / 180
    let a =
      sin(deltaLat / 2) * sin(deltaLat / 2)
      + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
    return earthRadiusMeters * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
  }

  static func interpolate(
    from first: MaritimeCoordinate,
    to second: MaritimeCoordinate,
    fraction: Double
  ) -> MaritimeCoordinate {
    let clamped = min(1, max(0, fraction))
    let longitudeDelta = wrappedLongitudeDelta(from: first.longitude, to: second.longitude)
    return MaritimeCoordinate(
      latitude: first.latitude + (second.latitude - first.latitude) * clamped,
      longitude: normalizeLongitude(first.longitude + longitudeDelta * clamped)
    )
  }

  static func wrappedLongitudeDelta(from first: Double, to second: Double) -> Double {
    var delta = second - first
    if delta > 180 { delta -= 360 }
    if delta < -180 { delta += 360 }
    return delta
  }

  static func normalizeLongitude(_ longitude: Double) -> Double {
    var value = longitude
    while value > 180 { value -= 360 }
    while value < -180 { value += 360 }
    return value
  }

  static func splitAtAntimeridian(_ coordinates: [MaritimeCoordinate]) -> [[MaritimeCoordinate]] {
    guard let first = coordinates.first else { return [] }
    guard coordinates.count > 1 else { return [[first]] }
    var result: [[MaritimeCoordinate]] = []
    var current = [first]

    for endpoint in coordinates.dropFirst() {
      guard let start = current.last else { continue }
      let rawDelta = endpoint.longitude - start.longitude
      if abs(rawDelta) <= 180 {
        current.append(endpoint)
        continue
      }

      let unwrappedEnd = endpoint.longitude + (rawDelta > 180 ? -360 : 360)
      let boundary = unwrappedEnd > start.longitude ? 180.0 : -180.0
      let fraction = (boundary - start.longitude) / (unwrappedEnd - start.longitude)
      let latitude = start.latitude + (endpoint.latitude - start.latitude) * fraction
      current.append(MaritimeCoordinate(latitude: latitude, longitude: boundary))
      result.append(current)
      current = [
        MaritimeCoordinate(latitude: latitude, longitude: boundary == 180 ? -180 : 180),
        endpoint,
      ]
    }
    result.append(current)
    return result
  }

  static func arrow(
    for coordinates: [MaritimeCoordinate]
  ) -> (coordinate: MaritimeCoordinate, rotationRadians: Double)? {
    guard coordinates.count > 1 else { return nil }
    let lengths = zip(coordinates, coordinates.dropFirst()).map(distance)
    let total = lengths.reduce(0, +)
    guard total > 10 else { return nil }
    let target = total / 2
    var covered = 0.0

    for (index, length) in lengths.enumerated() {
      if covered + length >= target {
        let fraction = (target - covered) / max(length, 1)
        let midpoint = interpolate(
          from: coordinates[index], to: coordinates[index + 1], fraction: fraction)
        let before = interpolate(
          from: coordinates[index], to: coordinates[index + 1], fraction: max(0, fraction - 0.01))
        let after = interpolate(
          from: coordinates[index], to: coordinates[index + 1], fraction: min(1, fraction + 0.01))
        let beforePoint = MKMapPoint(
          CLLocationCoordinate2D(latitude: before.latitude, longitude: before.longitude))
        var afterPoint = MKMapPoint(
          CLLocationCoordinate2D(latitude: after.latitude, longitude: after.longitude))
        let worldWidth = MKMapSize.world.width
        if afterPoint.x - beforePoint.x > worldWidth / 2 { afterPoint.x -= worldWidth }
        if beforePoint.x - afterPoint.x > worldWidth / 2 { afterPoint.x += worldWidth }
        return (
          midpoint,
          Double(atan2(afterPoint.y - beforePoint.y, afterPoint.x - beforePoint.x))
        )
      }
      covered += length
    }
    return nil
  }
}
