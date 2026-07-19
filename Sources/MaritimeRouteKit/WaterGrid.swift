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
  let hasGatewayDirections: Bool?
  let gateways: [Gateway]?
}

struct WaterGrid: Sendable {
  struct Cell: Hashable, Sendable {
    let row: Int
    let column: Int
  }

  let metadata: WaterGridMetadata
  private let bits: Data
  private let directionLayers: [Data]
  private let rowBytes: Int

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

  init(resource name: String) throws {
    guard let url = Bundle.module.url(forResource: name, withExtension: "mrkgrid") else {
      throw CocoaError(.fileNoSuchFile)
    }
    try self.init(url: url)
  }

  init(url: URL) throws {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard data.count >= 12, data.prefix(8) == Data("MRKGRID1".utf8) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let metadataLength = data[8..<12].enumerated().reduce(0) { partial, item in
      partial | (Int(item.element) << (item.offset * 8))
    }
    let metadataStart = 12
    let metadataEnd = metadataStart + metadataLength
    guard metadataEnd <= data.count else { throw CocoaError(.fileReadCorruptFile) }
    metadata = try JSONDecoder().decode(
      WaterGridMetadata.self, from: data[metadataStart..<metadataEnd])
    rowBytes = (metadata.columns + 7) / 8
    let waterBytes = rowBytes * metadata.rows
    let waterEnd = metadataEnd + waterBytes
    guard waterEnd <= data.count else { throw CocoaError(.fileReadCorruptFile) }
    bits = data[metadataEnd..<waterEnd]

    let expectedLayers =
      metadata.gateways?.isEmpty == false
      ? metadata.gateways!.count
      : (metadata.gatewayLatitude != nil && metadata.gatewayLongitude != nil ? 1 : 0)
    if metadata.hasGatewayDirections == true {
      let layerBytes = (metadata.rows * metadata.columns + 1) / 2
      guard expectedLayers > 0, data.count - waterEnd == layerBytes * expectedLayers else {
        throw CocoaError(.fileReadCorruptFile)
      }
      directionLayers = (0..<expectedLayers).map { index in
        let start = waterEnd + index * layerBytes
        return data[start..<(start + layerBytes)]
      }
    } else {
      guard data.count == waterEnd else { throw CocoaError(.fileReadCorruptFile) }
      directionLayers = []
    }
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
    if isGlobal {
      column = (column % metadata.columns + metadata.columns) % metadata.columns
    }
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
    guard (0..<metadata.rows).contains(cell.row), (0..<metadata.columns).contains(cell.column)
    else { return false }
    let byteIndex = cell.row * rowBytes + cell.column / 8
    let mask = UInt8(1 << (cell.column % 8))
    return bits[bits.startIndex + byteIndex] & mask != 0
  }

  func isRoutable(_ cell: Cell) -> Bool {
    guard isNavigable(cell) else { return false }
    guard !directionLayers.isEmpty else { return true }
    return directionLayers.indices.contains { gatewayDirection(at: cell, layer: $0) != 15 }
  }

  func neighboringCell(_ cell: Cell, rowOffset: Int, columnOffset: Int) -> Cell? {
    let row = cell.row + rowOffset
    guard (0..<metadata.rows).contains(row) else { return nil }
    var column = cell.column + columnOffset
    if isGlobal {
      column = (column % metadata.columns + metadata.columns) % metadata.columns
    }
    guard (0..<metadata.columns).contains(column) else { return nil }
    return Cell(row: row, column: column)
  }

  func nearestNavigable(to coordinate: MaritimeCoordinate, maximumDistance: Double) -> (
    Cell, Double
  )? {
    guard contains(coordinate), let center = cell(for: coordinate) else { return nil }
    if isRoutable(center) { return (center, 0) }
    let latitudeMeters = metadata.step * 111_195
    let longitudeMeters = max(1, latitudeMeters * abs(cos(coordinate.latitude * .pi / 180)))
    let rowRadius = Int(ceil(maximumDistance / latitudeMeters))
    let columnRadius = Int(ceil(maximumDistance / longitudeMeters))
    var best: (cell: Cell, distance: Double)?

    for rowOffset in -rowRadius...rowRadius {
      for columnOffset in -columnRadius...columnRadius {
        guard
          let candidate = neighboringCell(center, rowOffset: rowOffset, columnOffset: columnOffset),
          isRoutable(candidate)
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
    let distance = MaritimeGeometry.distance(start, end)
    let latitudeCellMeters = metadata.step * 111_195
    let sampleSpacing = max(40, min(1_000, latitudeCellMeters * 0.4))
    let samples = max(1, Int(ceil(distance / sampleSpacing)))
    for index in 0...samples {
      let fraction = Double(index) / Double(samples)
      let forward = MaritimeGeometry.interpolate(from: start, to: end, fraction: fraction)
      let reverse = MaritimeGeometry.interpolate(from: end, to: start, fraction: 1 - fraction)
      if !isNavigable(forward) || !isNavigable(reverse) {
        return false
      }
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

  func pathToGateway(from start: Cell, gatewayIndex: Int = 0) -> [Cell]? {
    guard directionLayers.indices.contains(gatewayIndex), isNavigable(start) else { return nil }
    let offsets = [
      (-1, 0), (-1, 1), (0, 1), (1, 1),
      (1, 0), (1, -1), (0, -1), (-1, -1),
    ]
    var result = [start]
    var cell = start
    while result.count <= metadata.rows * metadata.columns {
      let direction = gatewayDirection(at: cell, layer: gatewayIndex)
      if direction == 8 { return result }
      guard (0..<8).contains(direction),
        let next = neighboringCell(
          cell,
          rowOffset: offsets[direction].0,
          columnOffset: offsets[direction].1
        )
      else { return nil }
      result.append(next)
      cell = next
    }
    return nil
  }

  private func gatewayDirection(at cell: Cell, layer: Int) -> Int {
    guard directionLayers.indices.contains(layer) else { return 15 }
    let directions = directionLayers[layer]
    let linearIndex = cell.row * metadata.columns + cell.column
    let byte = directions[directions.startIndex + linearIndex / 2]
    return Int((byte >> UInt8(4 * (linearIndex % 2))) & 0x0F)
  }
}
