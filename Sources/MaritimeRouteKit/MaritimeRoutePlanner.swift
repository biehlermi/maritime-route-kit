import Foundation

/// Plans deterministic, offline, illustrative water routes.
///
/// MaritimeRouteKit is not a navigation system. Its geometric routes ignore
/// depth, shipping lanes, traffic rules, tides, weather, restrictions, canals,
/// locks, and vessel characteristics.
public actor MaritimeRoutePlanner {
  private var waterWorld: WaterWorld?
  private var dataLoadFailed = false

  public init() {}

  /// Plans consecutive legs in itinerary order without accessing the network.
  public func plan(stops: [MaritimeRouteStop]) async -> MaritimeRouteResult {
    let world: WaterWorld
    do {
      world = try loadedWorld()
    } catch {
      return dataUnavailableResult(stops: stops, error: error)
    }

    var placements: [MaritimeStopPlacement] = []
    var nodes: [PlacedWaterNode?] = []
    var diagnostics: [MaritimeRouteDiagnostic] = []

    for (index, stop) in stops.enumerated() {
      guard MaritimeGeometry.isValid(stop.coordinate) else {
        placements.append(
          MaritimeStopPlacement(
            inputIndex: index,
            stop: stop,
            status: .invalidCoordinate,
            normalizedCoordinate: nil,
            snapDistanceMeters: nil
          ))
        nodes.append(nil)
        diagnostics.append(
          MaritimeRouteDiagnostic(
            id: "invalid-stop-\(index)",
            kind: .invalidCoordinate,
            stopIndex: index,
            message: "Stop \(index + 1) has a non-finite or out-of-range coordinate."
          ))
        continue
      }

      guard let node = world.place(stop.coordinate, maximumSnapDistance: 25_000) else {
        placements.append(
          MaritimeStopPlacement(
            inputIndex: index,
            stop: stop,
            status: .noNavigableWaterWithin25Kilometers,
            normalizedCoordinate: nil,
            snapDistanceMeters: nil
          ))
        nodes.append(nil)
        diagnostics.append(
          MaritimeRouteDiagnostic(
            id: "unplaceable-stop-\(index)",
            kind: .stopCannotBePlaced,
            stopIndex: index,
            message:
              "No ocean-connected water represented by the bundled data lies within 25 km of \(stop.title)."
          ))
        continue
      }

      nodes.append(node)
      placements.append(
        MaritimeStopPlacement(
          inputIndex: index,
          stop: stop,
          status: .placed,
          normalizedCoordinate: node.coordinate,
          snapDistanceMeters: node.snapDistance
        ))
    }

    var legs: [MaritimeRouteLeg] = []
    if stops.count > 1 {
      for index in 0..<(stops.count - 1) {
        guard let start = nodes[index], let end = nodes[index + 1] else {
          diagnostics.append(
            MaritimeRouteDiagnostic(
              id: "unroutable-leg-\(index)",
              kind: .legCannotBeRouted,
              legStartIndex: index,
              message: "Leg \(index + 1) was omitted because one or both stops could not be placed."
            ))
          continue
        }

        let legID = "leg-\(index)-\(stops[index].id)-\(stops[index + 1].id)"
        if MaritimeGeometry.distance(start.coordinate, end.coordinate) < 1 {
          legs.append(
            MaritimeRouteLeg(
              id: legID,
              startIndex: index,
              endIndex: index + 1,
              startStopID: stops[index].id,
              endStopID: stops[index + 1].id,
              coordinates: [start.coordinate]
            ))
          continue
        }

        guard let coordinates = world.route(from: start, to: end) else {
          diagnostics.append(
            MaritimeRouteDiagnostic(
              id: "unroutable-leg-\(index)",
              kind: .legCannotBeRouted,
              legStartIndex: index,
              message:
                "No water-safe route was found for \(stops[index].title)–\(stops[index + 1].title)."
            ))
          continue
        }
        legs.append(
          MaritimeRouteLeg(
            id: legID,
            startIndex: index,
            endIndex: index + 1,
            startStopID: stops[index].id,
            endStopID: stops[index + 1].id,
            coordinates: coordinates
          ))
      }
    }

    return MaritimeRouteResult(placements: placements, legs: legs, diagnostics: diagnostics)
  }

  private func loadedWorld() throws -> WaterWorld {
    if let waterWorld { return waterWorld }
    if dataLoadFailed { throw CocoaError(.fileReadCorruptFile) }
    do {
      let loaded = try WaterWorld()
      waterWorld = loaded
      return loaded
    } catch {
      dataLoadFailed = true
      throw error
    }
  }

  private func dataUnavailableResult(stops: [MaritimeRouteStop], error: Error)
    -> MaritimeRouteResult
  {
    let placements = stops.enumerated().map { index, stop in
      MaritimeStopPlacement(
        inputIndex: index,
        stop: stop,
        status: MaritimeGeometry.isValid(stop.coordinate)
          ? .noNavigableWaterWithin25Kilometers : .invalidCoordinate,
        normalizedCoordinate: nil,
        snapDistanceMeters: nil
      )
    }
    return MaritimeRouteResult(
      placements: placements,
      legs: [],
      diagnostics: [
        MaritimeRouteDiagnostic(
          id: "routing-data-unavailable",
          kind: .routingDataUnavailable,
          message: "The bundled water dataset could not be loaded: \(error.localizedDescription)"
        )
      ]
    )
  }
}

struct PlacedWaterNode: Sendable {
  let coordinate: MaritimeCoordinate
  let snapDistance: Double
  let gridIndex: Int
}

struct WaterWorld: Sendable {
  let grids: [WaterGrid]
  let globalGridIndex: Int

  init() throws {
    grids = [
      try WaterGrid(resource: "bergen"),
      try WaterGrid(resource: "elbe"),
      try WaterGrid(resource: "geirangerfjord"),
      try WaterGrid(resource: "stockholm"),
      try WaterGrid(resource: "global-ocean"),
    ]
    globalGridIndex = grids.count - 1
  }

  func place(_ coordinate: MaritimeCoordinate, maximumSnapDistance: Double) -> PlacedWaterNode? {
    var best: PlacedWaterNode?
    for (index, grid) in grids.enumerated() where grid.contains(coordinate) {
      if let cell = grid.cell(for: coordinate), grid.isRoutable(cell) {
        let candidate = PlacedWaterNode(coordinate: coordinate, snapDistance: 0, gridIndex: index)
        if best == nil || candidate.snapDistance < best!.snapDistance { best = candidate }
        continue
      }
      guard
        let (cell, distance) = grid.nearestNavigable(
          to: coordinate, maximumDistance: maximumSnapDistance)
      else {
        continue
      }
      let candidate = PlacedWaterNode(
        coordinate: grid.coordinate(for: cell),
        snapDistance: distance,
        gridIndex: index
      )
      if best == nil || candidate.snapDistance < best!.snapDistance { best = candidate }
    }
    return best
  }

  func route(from start: PlacedWaterNode, to end: PlacedWaterNode) -> [MaritimeCoordinate]? {
    if start.gridIndex == end.gridIndex, start.gridIndex != globalGridIndex {
      return route(on: grids[start.gridIndex], from: start.coordinate, to: end.coordinate)
    }

    var sections: [[MaritimeCoordinate]] = []
    var globalStart = start.coordinate
    var globalEnd = end.coordinate

    if start.gridIndex != globalGridIndex {
      let grid = grids[start.gridIndex]
      guard let gateway = grid.gateway,
        let local = route(on: grid, from: start.coordinate, to: gateway)
      else { return nil }
      sections.append(local)
      globalStart = gateway
    }
    if end.gridIndex != globalGridIndex {
      guard let gateway = grids[end.gridIndex].gateway else { return nil }
      globalEnd = gateway
    }

    guard let global = route(on: grids[globalGridIndex], from: globalStart, to: globalEnd) else {
      return nil
    }
    sections.append(global)

    if end.gridIndex != globalGridIndex {
      let grid = grids[end.gridIndex]
      guard let local = route(on: grid, from: globalEnd, to: end.coordinate) else { return nil }
      sections.append(local)
    }

    var result: [MaritimeCoordinate] = []
    for section in sections {
      for coordinate in section
      where result.last.map({ MaritimeGeometry.distance($0, coordinate) >= 1 }) ?? true {
        result.append(coordinate)
      }
    }
    return result.count > 1 ? result : nil
  }

  func isNavigableSegment(from start: MaritimeCoordinate, to end: MaritimeCoordinate) -> Bool {
    grids.contains { grid in
      grid.contains(start) && grid.contains(end) && grid.segmentIsNavigable(from: start, to: end)
    }
  }

  private func route(
    on grid: WaterGrid,
    from start: MaritimeCoordinate,
    to end: MaritimeCoordinate
  ) -> [MaritimeCoordinate]? {
    guard grid.isNavigable(start), grid.isNavigable(end),
      let startCell = grid.cell(for: start), let goalCell = grid.cell(for: end)
    else { return nil }
    if grid.segmentIsNavigable(from: start, to: end) { return [start, end] }
    if !grid.isGlobal {
      return routeUsingGatewayTree(
        on: grid,
        from: start,
        startCell: startCell,
        to: end,
        goalCell: goalCell
      )
    }

    struct Frontier: Comparable {
      let estimatedTotal: Double
      let heuristic: Double
      let cost: Double
      let serial: Int
      let cell: WaterGrid.Cell

      static func < (lhs: Frontier, rhs: Frontier) -> Bool {
        if lhs.estimatedTotal != rhs.estimatedTotal {
          return lhs.estimatedTotal < rhs.estimatedTotal
        }
        if lhs.heuristic != rhs.heuristic { return lhs.heuristic < rhs.heuristic }
        return lhs.serial < rhs.serial
      }
    }

    let unitDirections = [
      (-1, 0), (-1, 1), (0, 1), (1, 1),
      (1, 0), (1, -1), (0, -1), (-1, -1),
    ]
    let strides = grid.isGlobal ? [1] : [8, 4, 2]
    let directDistance = MaritimeGeometry.distance(start, end)
    let maximumEstimatedCost =
      grid.isGlobal
      ? directDistance * 4 + 700_000
      : directDistance * 3 + 250_000
    var frontier = PriorityQueue<Frontier>()
    var costs: [WaterGrid.Cell: Double] = [startCell: 0]
    var parents: [WaterGrid.Cell: WaterGrid.Cell] = [:]
    var incomingDirections: [WaterGrid.Cell: Int] = [:]
    var serial = 0
    var winningCell: WaterGrid.Cell?
    frontier.push(
      Frontier(
        estimatedTotal: directDistance,
        heuristic: directDistance,
        cost: 0,
        serial: serial,
        cell: startCell
      ))

    while let current = frontier.pop(), winningCell == nil {
      guard let currentCost = costs[current.cell], currentCost == current.cost else { continue }
      if current.cell == goalCell
        || (!grid.isGlobal
          && current.heuristic < 12_000
          && grid.segmentIsNavigable(from: grid.coordinate(for: current.cell), to: end))
      {
        winningCell = current.cell
        break
      }
      if current.estimatedTotal > maximumEstimatedCost
        || costs.count > (grid.isGlobal ? 300_000 : 150_000)
      {
        break
      }
      let currentCoordinate = grid.coordinate(for: current.cell)
      let currentDirection = incomingDirections[current.cell]

      for stride in strides {
        for (direction, offset) in unitDirections.enumerated() {
          guard
            let nextCell = grid.neighboringCell(
              current.cell,
              rowOffset: offset.0 * stride,
              columnOffset: offset.1 * stride
            ), grid.isNavigable(nextCell)
          else { continue }
          let nextCoordinate = grid.coordinate(for: nextCell)
          guard grid.segmentIsNavigable(from: currentCoordinate, to: nextCoordinate) else {
            continue
          }
          let stepDistance = MaritimeGeometry.distance(currentCoordinate, nextCoordinate)
          let turnMultiplier = currentDirection == nil || currentDirection == direction ? 0 : 0.035
          let nextCost =
            currentCost + stepDistance * (1 + turnMultiplier + grid.shorePenalty(at: nextCell))
          if let oldCost = costs[nextCell], oldCost <= nextCost { continue }
          costs[nextCell] = nextCost
          parents[nextCell] = current.cell
          incomingDirections[nextCell] = direction
          let heuristic = MaritimeGeometry.distance(nextCoordinate, end)
          serial += 1
          frontier.push(
            Frontier(
              estimatedTotal: nextCost + heuristic,
              heuristic: heuristic,
              cost: nextCost,
              serial: serial,
              cell: nextCell
            ))
        }
      }
    }

    guard var cell = winningCell else { return nil }
    var reversedCells = [cell]
    while cell != startCell {
      guard let parent = parents[cell] else { return nil }
      cell = parent
      reversedCells.append(cell)
    }
    var path = [start]
    path.append(contentsOf: reversedCells.reversed().dropFirst().map(grid.coordinate(for:)))
    path.append(end)
    let simplified = simplify(path, on: grid)
    return rounded(simplified, on: grid)
  }

  private func routeUsingGatewayTree(
    on grid: WaterGrid,
    from start: MaritimeCoordinate,
    startCell: WaterGrid.Cell,
    to end: MaritimeCoordinate,
    goalCell: WaterGrid.Cell
  ) -> [MaritimeCoordinate]? {
    guard let startPath = grid.pathToGateway(from: startCell),
      let goalPath = grid.pathToGateway(from: goalCell)
    else { return nil }
    let startIndices = Dictionary(
      uniqueKeysWithValues: startPath.enumerated().map { ($0.element, $0.offset) })
    guard
      let intersection = goalPath.enumerated().first(where: { startIndices[$0.element] != nil }),
      let startIntersectionIndex = startIndices[intersection.element]
    else { return nil }

    var cells = Array(startPath[0...startIntersectionIndex])
    if intersection.offset > 0 {
      cells.append(contentsOf: goalPath[..<intersection.offset].reversed())
    }
    var path = [start]
    for cell in cells
    where path.last.map({ MaritimeGeometry.distance($0, grid.coordinate(for: cell)) >= 1 }) ?? true
    {
      path.append(grid.coordinate(for: cell))
    }
    if path.last.map({ MaritimeGeometry.distance($0, end) >= 1 }) ?? true { path.append(end) }
    for (first, second) in zip(path, path.dropFirst()) {
      guard grid.segmentIsNavigable(from: first, to: second) else { return nil }
    }
    return rounded(simplify(path, on: grid), on: grid)
  }

  private func simplify(_ path: [MaritimeCoordinate], on grid: WaterGrid) -> [MaritimeCoordinate] {
    guard path.count > 2 else { return path }
    var result = [path[0]]
    var index = 0
    while index < path.count - 1 {
      var candidate = min(path.count - 1, index + 160)
      while candidate > index + 1,
        !grid.segmentIsNavigable(from: path[index], to: path[candidate])
      {
        candidate -= 1
      }
      result.append(path[candidate])
      index = candidate
    }
    return result
  }

  private func rounded(_ path: [MaritimeCoordinate], on grid: WaterGrid) -> [MaritimeCoordinate] {
    guard path.count > 2 else { return path }
    var candidate = [path[0]]
    for index in 0..<(path.count - 1) {
      let start = path[index]
      let end = path[index + 1]
      candidate.append(MaritimeGeometry.interpolate(from: start, to: end, fraction: 0.25))
      candidate.append(MaritimeGeometry.interpolate(from: start, to: end, fraction: 0.75))
    }
    candidate.append(path[path.count - 1])
    for (start, end) in zip(candidate, candidate.dropFirst()) {
      if !grid.segmentIsNavigable(from: start, to: end) { return path }
    }
    return candidate
  }
}
