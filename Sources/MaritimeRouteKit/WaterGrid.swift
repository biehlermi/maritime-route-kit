import Foundation

struct WaterGridMetadata: Decodable, Sendable {
  struct Gateway: Decodable, Sendable {
    let latitude: Double
    let longitude: Double
  }

  let name: String
  let kind: String
  let minLatitude: Double
  let minLongitude: Double
  let step: Double
  let rows: Int
  let columns: Int
  let clearanceMeters: Double
  let gatewayLatitude: Double?
  let gatewayLongitude: Double?
  let gateways: [Gateway]?
}

/// A lightweight view over one grid embedded in `world.mrkroute`.
struct WaterGrid: Sendable {
  struct Cell: Hashable, Sendable {
    let row: Int
    let column: Int
  }

  let metadata: WaterGridMetadata
  let gridIndex: Int
  let resource: WorldRouteResource

  var isGlobal: Bool { metadata.kind == "global" }
  var gateways: [MaritimeCoordinate] {
    if let gateways = metadata.gateways, !gateways.isEmpty {
      return gateways.map {
        MaritimeCoordinate(latitude: $0.latitude, longitude: $0.longitude)
      }
    }
    guard let latitude = metadata.gatewayLatitude, let longitude = metadata.gatewayLongitude else {
      return []
    }
    return [MaritimeCoordinate(latitude: latitude, longitude: longitude)]
  }

  func contains(_ coordinate: MaritimeCoordinate) -> Bool {
    coordinate.latitude >= metadata.minLatitude
      && coordinate.latitude < metadata.minLatitude + Double(metadata.rows) * metadata.step
      && (isGlobal
        || (coordinate.longitude >= metadata.minLongitude
          && coordinate.longitude < metadata.minLongitude + Double(metadata.columns) * metadata.step))
  }

  func cell(for coordinate: MaritimeCoordinate) -> Cell? {
    guard contains(coordinate) else { return nil }
    let row = Int(floor((coordinate.latitude - metadata.minLatitude) / metadata.step))
    var column = Int(floor((coordinate.longitude - metadata.minLongitude) / metadata.step))
    if isGlobal { column = (column % metadata.columns + metadata.columns) % metadata.columns }
    guard (0..<metadata.rows).contains(row), (0..<metadata.columns).contains(column) else {
      return nil
    }
    return Cell(row: row, column: column)
  }

  func coordinate(for cell: Cell) -> MaritimeCoordinate {
    MaritimeCoordinate(
      latitude: metadata.minLatitude + (Double(cell.row) + 0.5) * metadata.step,
      longitude: MaritimeGeometry.normalizeLongitude(
        metadata.minLongitude + (Double(cell.column) + 0.5) * metadata.step
      )
    )
  }

  func isNavigable(_ coordinate: MaritimeCoordinate) -> Bool {
    guard let cell = cell(for: coordinate) else { return false }
    return isNavigable(cell)
  }

  func isNavigable(_ cell: Cell) -> Bool {
    resource.isNavigable(gridIndex: gridIndex, row: cell.row, column: cell.column)
  }

  func isRoutable(_ cell: Cell) -> Bool { isNavigable(cell) }

  func neighboringCell(_ cell: Cell, rowOffset: Int, columnOffset: Int) -> Cell? {
    let row = cell.row + rowOffset
    guard (0..<metadata.rows).contains(row) else { return nil }
    var column = cell.column + columnOffset
    if isGlobal { column = (column % metadata.columns + metadata.columns) % metadata.columns }
    guard (0..<metadata.columns).contains(column) else { return nil }
    return Cell(row: row, column: column)
  }

  func tileIndex(for cell: Cell) -> Int? {
    resource.tileIndex(gridIndex: gridIndex, row: cell.row, column: cell.column)
  }

  func nearestNavigable(to coordinate: MaritimeCoordinate, maximumDistance: Double) -> (
    Cell, Double
  )? {
    guard contains(coordinate), let center = cell(for: coordinate) else { return nil }
    if isNavigable(center) { return (center, 0) }
    let latitudeMeters = metadata.step * 111_195
    let longitudeMeters = max(1, latitudeMeters * abs(cos(coordinate.latitude * .pi / 180)))
    let rowRadius = Int(ceil(maximumDistance / latitudeMeters))
    let columnRadius = Int(ceil(maximumDistance / longitudeMeters))
    var best: (cell: Cell, distance: Double)?

    for rowOffset in -rowRadius...rowRadius {
      for columnOffset in -columnRadius...columnRadius {
        guard
          let candidate = neighboringCell(center, rowOffset: rowOffset, columnOffset: columnOffset),
          isNavigable(candidate)
        else { continue }
        let distance = MaritimeGeometry.distance(coordinate, self.coordinate(for: candidate))
        if distance <= maximumDistance,
          best == nil || distance < best!.distance
            || (distance == best!.distance
              && (candidate.row, candidate.column) < (best!.cell.row, best!.cell.column))
        {
          best = (candidate, distance)
        }
      }
    }
    return best.map { ($0.cell, $0.distance) }
  }

  func segmentIsNavigable(from start: MaritimeCoordinate, to end: MaritimeCoordinate) -> Bool {
    guard contains(start), contains(end) else { return false }
    let distance = MaritimeGeometry.distance(start, end)
    let latitudeCellMeters = metadata.step * 111_195
    let sampleSpacing = max(15, min(1_000, latitudeCellMeters * 0.35))
    let samples = max(1, Int(ceil(distance / sampleSpacing)))
    for index in 0...samples {
      let fraction = Double(index) / Double(samples)
      let forward = MaritimeGeometry.interpolate(from: start, to: end, fraction: fraction)
      let reverse = MaritimeGeometry.interpolate(from: end, to: start, fraction: 1 - fraction)
      if !isNavigable(forward) || !isNavigable(reverse) { return false }
    }
    return true
  }

  func shorePenalty(at cell: Cell) -> Double {
    guard !isGlobal else { return 0 }
    for (radius, penalty) in [(2, 0.30), (5, 0.14), (10, 0.05)] {
      for (rowOffset, columnOffset) in [
        (-radius, 0), (radius, 0), (0, -radius), (0, radius),
        (-radius, -radius), (-radius, radius), (radius, -radius), (radius, radius),
      ] {
        guard let nearby = neighboringCell(cell, rowOffset: rowOffset, columnOffset: columnOffset),
          isNavigable(nearby)
        else { return penalty }
      }
    }
    return 0
  }
}
