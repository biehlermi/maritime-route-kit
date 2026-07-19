import Foundation

/// Plans deterministic, offline, illustrative water routes.
///
/// MaritimeRouteKit is not a navigation system. Its geometric routes ignore
/// depth, shipping lanes, traffic rules, tides, weather, restrictions, lock
/// operations, and vessel characteristics.
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
  private struct Access: Sendable {
    let coordinate: MaritimeCoordinate
    let pathFromEndpoint: [MaritimeCoordinate]
    let cost: Double
    let sourceGridIndex: Int?
  }

  private struct ConnectorTransition: Sendable {
    let gridIndex: Int
    let start: MaritimeCoordinate
    let end: MaritimeCoordinate
    let path: [MaritimeCoordinate]
    let cost: Double
  }

  let grids: [WaterGrid]
  let globalGridIndex: Int
  private let connectorTransitions: [ConnectorTransition]

  init() throws {
    guard
      let urls = Bundle.module.urls(forResourcesWithExtension: "mrkgrid", subdirectory: nil),
      !urls.isEmpty
    else { throw CocoaError(.fileNoSuchFile) }
    let loaded = try urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map(WaterGrid.init)
    let globalIndices = loaded.indices.filter { loaded[$0].isGlobal }
    guard globalIndices.count == 1, let globalIndex = globalIndices.first else {
      throw CocoaError(.fileReadCorruptFile)
    }

    var transitions: [ConnectorTransition] = []
    for (gridIndex, grid) in loaded.enumerated() where grid.gateways.count > 1 {
      for firstIndex in 0..<(grid.gateways.count - 1) {
        for secondIndex in (firstIndex + 1)..<grid.gateways.count {
          let first = grid.gateways[firstIndex]
          let second = grid.gateways[secondIndex]
          guard let path = Self.routeLocally(on: grid, from: first, to: second) else {
            throw CocoaError(.fileReadCorruptFile)
          }
          let cost = Self.pathLength(path)
          transitions.append(
            ConnectorTransition(
              gridIndex: gridIndex, start: first, end: second, path: path, cost: cost))
          transitions.append(
            ConnectorTransition(
              gridIndex: gridIndex,
              start: second,
              end: first,
              path: path.reversed(),
              cost: cost
            ))
        }
      }
    }

    grids = loaded
    globalGridIndex = globalIndex
    connectorTransitions = transitions
  }

  func place(_ coordinate: MaritimeCoordinate, maximumSnapDistance: Double) -> PlacedWaterNode? {
    var best: PlacedWaterNode?
    for (index, grid) in grids.enumerated() where grid.contains(coordinate) {
      if let cell = grid.cell(for: coordinate), grid.isRoutable(cell) {
        let candidate = PlacedWaterNode(coordinate: coordinate, snapDistance: 0, gridIndex: index)
        if isBetterPlacement(candidate, than: best) { best = candidate }
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
      if isBetterPlacement(candidate, than: best) { best = candidate }
    }
    return best
  }

  func route(from start: PlacedWaterNode, to end: PlacedWaterNode) -> [MaritimeCoordinate]? {
    if start.gridIndex == end.gridIndex, start.gridIndex != globalGridIndex {
      return Self.routeLocally(
        on: grids[start.gridIndex], from: start.coordinate, to: end.coordinate)
    }

    guard let starts = accesses(for: start), let ends = accesses(for: end),
      let path = routeThroughGlobalNetwork(from: starts, to: ends)
    else { return nil }
    return path.count > 1 ? path : nil
  }

  func isNavigableSegment(from start: MaritimeCoordinate, to end: MaritimeCoordinate) -> Bool {
    grids.contains { grid in
      grid.contains(start) && grid.contains(end) && grid.segmentIsNavigable(from: start, to: end)
    }
  }

  private func isBetterPlacement(_ candidate: PlacedWaterNode, than current: PlacedWaterNode?)
    -> Bool
  {
    guard let current else { return true }
    if candidate.snapDistance != current.snapDistance {
      return candidate.snapDistance < current.snapDistance
    }
    let candidateStep = grids[candidate.gridIndex].metadata.step
    let currentStep = grids[current.gridIndex].metadata.step
    if candidateStep != currentStep { return candidateStep < currentStep }
    return candidate.gridIndex < current.gridIndex
  }

  private func accesses(for node: PlacedWaterNode) -> [Access]? {
    if node.gridIndex == globalGridIndex {
      return [
        Access(
          coordinate: node.coordinate,
          pathFromEndpoint: [node.coordinate],
          cost: 0,
          sourceGridIndex: nil
        )
      ]
    }
    let grid = grids[node.gridIndex]
    let accesses = grid.gateways.indices.compactMap { gatewayIndex -> Access? in
      guard
        let path = Self.routeToGateway(
          on: grid, from: node.coordinate, gatewayIndex: gatewayIndex)
      else { return nil }
      return Access(
        coordinate: grid.gateways[gatewayIndex],
        pathFromEndpoint: path,
        cost: Self.pathLength(path),
        sourceGridIndex: node.gridIndex
      )
    }
    return accesses.isEmpty ? nil : accesses
  }

  private func routeThroughGlobalNetwork(from starts: [Access], to ends: [Access])
    -> [MaritimeCoordinate]?
  {
    let directEstimate = starts.flatMap { start in
      ends.map { end in
        start.cost + MaritimeGeometry.distance(start.coordinate, end.coordinate) + end.cost
      }
    }.min() ?? .infinity
    var candidates: [(index: Int, estimate: Double)] = []
    for (index, transition) in connectorTransitions.enumerated() {
      if starts.contains(where: { $0.sourceGridIndex == transition.gridIndex })
        || ends.contains(where: { $0.sourceGridIndex == transition.gridIndex })
      {
        continue
      }
      var estimate = Double.infinity
      for start in starts {
        let approach = start.cost + MaritimeGeometry.distance(start.coordinate, transition.start)
        for end in ends {
          let departure = MaritimeGeometry.distance(transition.end, end.coordinate) + end.cost
          estimate = min(estimate, approach + transition.cost + departure)
        }
      }
      if estimate <= directEstimate * 1.15 + 100_000 {
        candidates.append((index: index, estimate: estimate))
      }
    }
    candidates.sort {
      $0.estimate != $1.estimate ? $0.estimate < $1.estimate : $0.index < $1.index
    }

    for candidate in candidates.prefix(2) {
      let transition = connectorTransitions[candidate.index]
      let entrance = Access(
        coordinate: transition.start,
        pathFromEndpoint: [transition.start],
        cost: 0,
        sourceGridIndex: nil
      )
      let exit = Access(
        coordinate: transition.end,
        pathFromEndpoint: [transition.end],
        cost: 0,
        sourceGridIndex: nil
      )
      guard
        let approach = routeAcrossGlobalGrid(
          from: starts, to: [entrance], connectorTransitions: []),
        let departure = routeAcrossGlobalGrid(
          from: [exit], to: ends, connectorTransitions: [])
      else { continue }
      let path = Self.join(
        [approach, transition.path, departure] as [[MaritimeCoordinate]])
      let rounded = roundedAcrossAvailableGrids(simplifyAcrossAvailableGrids(path))
      return repairRasterCornerCuts(in: rounded)
    }

    return routeAcrossGlobalGrid(from: starts, to: ends, connectorTransitions: [])
  }

  private func routeAcrossGlobalGrid(
    from starts: [Access],
    to ends: [Access],
    connectorTransitions: [ConnectorTransition]
  ) -> [MaritimeCoordinate]? {
    let grid = grids[globalGridIndex]

    enum Parent: Sendable {
      case adjacent(WaterGrid.Cell)
      case connector(WaterGrid.Cell, [MaritimeCoordinate])
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

    struct SearchState {
      var frontier = PriorityQueue<Frontier>()
      var costs: [WaterGrid.Cell: Double] = [:]
      var parents: [WaterGrid.Cell: Parent] = [:]
      var incomingDirections: [WaterGrid.Cell: Int] = [:]
      var accessIndicesByRoot: [WaterGrid.Cell: Int] = [:]
      var serial = 0
    }

    var transitionIndicesByCell: [WaterGrid.Cell: [Int]] = [:]
    for (index, transition) in connectorTransitions.enumerated() {
      guard grid.isNavigable(transition.start), grid.isNavigable(transition.end),
        let cell = grid.cell(for: transition.start), grid.cell(for: transition.end) != nil
      else { continue }
      transitionIndicesByCell[cell, default: []].append(index)
    }

    func heuristic(from coordinate: MaritimeCoordinate, toward accesses: [Access]) -> Double {
      var estimates = accesses.compactMap { access -> Double? in
        guard grid.isNavigable(access.coordinate) else { return nil }
        return MaritimeGeometry.distance(coordinate, access.coordinate) + access.cost
      }
      for transition in connectorTransitions {
        for access in accesses {
          let viaConnector =
            MaritimeGeometry.distance(coordinate, transition.start)
            + transition.cost
            + MaritimeGeometry.distance(transition.end, access.coordinate)
            + access.cost
          // A small lower-bound discount makes geographically useful connector
          // entrances competitive with a direct great-circle line through land.
          estimates.append(viaConnector * 0.9)
        }
      }
      return estimates.min() ?? .infinity
    }

    func initialState(for accesses: [Access], toward targets: [Access]) -> SearchState {
      var state = SearchState()
      for (index, access) in accesses.enumerated() {
        guard grid.isNavigable(access.coordinate), let cell = grid.cell(for: access.coordinate)
        else { continue }
        let center = grid.coordinate(for: cell)
        guard grid.segmentIsNavigable(from: access.coordinate, to: center) else { continue }
        let cost = access.cost + MaritimeGeometry.distance(access.coordinate, center)
        if let oldCost = state.costs[cell], oldCost <= cost { continue }
        state.costs[cell] = cost
        state.accessIndicesByRoot[cell] = index
        let estimate = heuristic(from: center, toward: targets)
        state.frontier.push(
          Frontier(
            estimatedTotal: cost + estimate,
            heuristic: estimate,
            cost: cost,
            serial: state.serial,
            cell: cell
          ))
        state.serial += 1
      }
      return state
    }

    let directions = [
      (-1, 0), (-1, 1), (0, 1), (1, 1),
      (1, 0), (1, -1), (0, -1), (-1, -1),
    ]

    func expand(_ state: inout SearchState, toward targets: [Access]) -> WaterGrid.Cell? {
      var current: Frontier?
      while let candidate = state.frontier.pop() {
        if state.costs[candidate.cell] == candidate.cost {
          current = candidate
          break
        }
      }
      guard let current, let currentCost = state.costs[current.cell] else { return nil }
      let currentCoordinate = grid.coordinate(for: current.cell)
      let currentDirection = state.incomingDirections[current.cell]
      for (direction, offset) in directions.enumerated() {
        guard
          let nextCell = grid.neighboringCell(
            current.cell, rowOffset: offset.0, columnOffset: offset.1),
          grid.isNavigable(nextCell)
        else { continue }
        let nextCoordinate = grid.coordinate(for: nextCell)
        guard grid.segmentIsNavigable(from: currentCoordinate, to: nextCoordinate) else {
          continue
        }
        let stepDistance = MaritimeGeometry.distance(currentCoordinate, nextCoordinate)
        let turnMultiplier = currentDirection == nil || currentDirection == direction ? 0 : 0.035
        let nextCost = currentCost + stepDistance * (1 + turnMultiplier)
        guard state.costs[nextCell].map({ $0 > nextCost }) ?? true else { continue }
        state.costs[nextCell] = nextCost
        state.parents[nextCell] = .adjacent(current.cell)
        state.incomingDirections[nextCell] = direction
        let nextHeuristic = heuristic(from: nextCoordinate, toward: targets)
        state.frontier.push(
          Frontier(
            estimatedTotal: nextCost + nextHeuristic,
            heuristic: nextHeuristic,
            cost: nextCost,
            serial: state.serial,
            cell: nextCell
          ))
        state.serial += 1
      }

      for transitionIndex in transitionIndicesByCell[current.cell] ?? [] {
        let transition = connectorTransitions[transitionIndex]
        guard let nextCell = grid.cell(for: transition.end) else { continue }
        let nextCoordinate = grid.coordinate(for: nextCell)
        let section = Self.join([
          [currentCoordinate, transition.start], transition.path,
          [transition.end, nextCoordinate],
        ])
        let nextCost = currentCost + Self.pathLength(section)
        guard state.costs[nextCell].map({ $0 > nextCost }) ?? true else { continue }
        state.costs[nextCell] = nextCost
        state.parents[nextCell] = .connector(current.cell, section)
        state.incomingDirections[nextCell] = nil
        let nextHeuristic = heuristic(from: nextCoordinate, toward: targets)
        state.frontier.push(
          Frontier(
            estimatedTotal: nextCost + nextHeuristic,
            heuristic: nextHeuristic,
            cost: nextCost,
            serial: state.serial,
            cell: nextCell
          ))
        state.serial += 1
      }
      return current.cell
    }

    var forward = initialState(for: starts, toward: ends)
    var backward = initialState(for: ends, toward: starts)
    guard !forward.costs.isEmpty, !backward.costs.isEmpty else { return nil }

    var meetingCell = forward.costs.keys
      .filter { backward.costs[$0] != nil }
      .sorted {
        $0.row != $1.row ? $0.row < $1.row : $0.column < $1.column
      }
      .first
    while meetingCell == nil, forward.costs.count + backward.costs.count <= 500_000 {
      guard let forwardCell = expand(&forward, toward: ends) else { break }
      if backward.costs[forwardCell] != nil {
        meetingCell = forwardCell
        break
      }
      guard let backwardCell = expand(&backward, toward: starts) else { break }
      if forward.costs[backwardCell] != nil {
        meetingCell = backwardCell
      }
    }
    guard let meetingCell else { return nil }

    var cell = meetingCell
    var reversedForwardSections: [[MaritimeCoordinate]] = []
    while let parent = forward.parents[cell] {
      switch parent {
      case .adjacent(let previous):
        reversedForwardSections.append([grid.coordinate(for: previous), grid.coordinate(for: cell)])
        cell = previous
      case .connector(let previous, let section):
        reversedForwardSections.append(section)
        cell = previous
      }
    }
    guard let startIndex = forward.accessIndicesByRoot[cell] else { return nil }
    let forwardRoot = cell

    cell = meetingCell
    var backwardSections: [[MaritimeCoordinate]] = []
    while let parent = backward.parents[cell] {
      switch parent {
      case .adjacent(let next):
        backwardSections.append([grid.coordinate(for: cell), grid.coordinate(for: next)])
        cell = next
      case .connector(let next, let section):
        backwardSections.append(Array(section.reversed()))
        cell = next
      }
    }
    guard let endIndex = backward.accessIndicesByRoot[cell] else { return nil }
    let backwardRoot = cell

    let startAccess = starts[startIndex]
    let endAccess = ends[endIndex]
    var sections = [startAccess.pathFromEndpoint]
    sections.append([startAccess.coordinate, grid.coordinate(for: forwardRoot)])
    sections.append(contentsOf: reversedForwardSections.reversed())
    sections.append(contentsOf: backwardSections)
    sections.append([grid.coordinate(for: backwardRoot), endAccess.coordinate])
    sections.append(Array(endAccess.pathFromEndpoint.reversed()))
    let path = Self.join(sections)
    let simplified = simplifyAcrossAvailableGrids(path)
    return repairRasterCornerCuts(in: roundedAcrossAvailableGrids(simplified))
  }

  private static func routeLocally(
    on grid: WaterGrid,
    from start: MaritimeCoordinate,
    to end: MaritimeCoordinate
  ) -> [MaritimeCoordinate]? {
    guard grid.isNavigable(start), grid.isNavigable(end),
      let startCell = grid.cell(for: start), let goalCell = grid.cell(for: end)
    else { return nil }
    if grid.segmentIsNavigable(from: start, to: end) { return [start, end] }
    let candidates = grid.gateways.indices.compactMap { gatewayIndex in
      routeUsingGatewayTree(
        on: grid,
        from: start,
        startCell: startCell,
        to: end,
        goalCell: goalCell,
        gatewayIndex: gatewayIndex
      )
    }
    return candidates.min { pathLength($0) < pathLength($1) }
  }

  private static func routeToGateway(
    on grid: WaterGrid,
    from start: MaritimeCoordinate,
    gatewayIndex: Int
  ) -> [MaritimeCoordinate]? {
    guard grid.gateways.indices.contains(gatewayIndex), grid.isNavigable(start),
      let startCell = grid.cell(for: start),
      let cells = grid.pathToGateway(from: startCell, gatewayIndex: gatewayIndex)
    else { return nil }
    let gateway = grid.gateways[gatewayIndex]
    var path = [start]
    path.append(contentsOf: cells.dropFirst().map(grid.coordinate(for:)))
    if path.last.map({ MaritimeGeometry.distance($0, gateway) >= 1 }) ?? true {
      path.append(gateway)
    }
    for (first, second) in zip(path, path.dropFirst()) {
      guard grid.segmentIsNavigable(from: first, to: second) else { return nil }
    }
    return rounded(simplify(path, on: grid), on: grid)
  }

  private static func routeUsingGatewayTree(
    on grid: WaterGrid,
    from start: MaritimeCoordinate,
    startCell: WaterGrid.Cell,
    to end: MaritimeCoordinate,
    goalCell: WaterGrid.Cell,
    gatewayIndex: Int
  ) -> [MaritimeCoordinate]? {
    guard let startPath = grid.pathToGateway(from: startCell, gatewayIndex: gatewayIndex),
      let goalPath = grid.pathToGateway(from: goalCell, gatewayIndex: gatewayIndex)
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

  private func simplifyAcrossAvailableGrids(_ path: [MaritimeCoordinate])
    -> [MaritimeCoordinate]
  {
    guard path.count > 2 else { return path }
    var result = [path[0]]
    var index = 0
    while index < path.count - 1 {
      var candidate = min(path.count - 1, index + 160)
      while candidate > index + 1,
        !isNavigableSegment(from: path[index], to: path[candidate])
      {
        candidate -= 1
      }
      result.append(path[candidate])
      index = candidate
    }
    return result
  }

  private func roundedAcrossAvailableGrids(_ path: [MaritimeCoordinate])
    -> [MaritimeCoordinate]
  {
    guard path.count > 2 else { return path }
    var candidate = [path[0]]
    for index in 0..<(path.count - 1) {
      candidate.append(
        MaritimeGeometry.interpolate(from: path[index], to: path[index + 1], fraction: 0.25))
      candidate.append(
        MaritimeGeometry.interpolate(from: path[index], to: path[index + 1], fraction: 0.75))
    }
    candidate.append(path[path.count - 1])
    for (start, end) in zip(candidate, candidate.dropFirst()) {
      if !isNavigableSegment(from: start, to: end) { return path }
    }
    return candidate
  }

  private func repairRasterCornerCuts(in path: [MaritimeCoordinate])
    -> [MaritimeCoordinate]?
  {
    guard let first = path.first else { return [] }
    var result = [first]
    for end in path.dropFirst() {
      let start = result.last!
      if isNavigableSegment(from: start, to: end) {
        result.append(end)
        continue
      }

      var repaired = false
      for grid in grids where grid.contains(start) && grid.contains(end) {
        guard let startCell = grid.cell(for: start), let endCell = grid.cell(for: end),
          abs(startCell.row - endCell.row) <= 1,
          abs(startCell.column - endCell.column) <= 1
        else { continue }
        let candidates = [
          WaterGrid.Cell(row: startCell.row, column: endCell.column),
          WaterGrid.Cell(row: endCell.row, column: startCell.column),
        ]
        for cell in candidates where grid.isNavigable(cell) {
          let corner = grid.coordinate(for: cell)
          if grid.segmentIsNavigable(from: start, to: corner),
            grid.segmentIsNavigable(from: corner, to: end)
          {
            result.append(corner)
            result.append(end)
            repaired = true
            break
          }
        }
        if repaired { break }
      }
      if !repaired { return nil }
    }
    return result
  }

  private static func simplify(_ path: [MaritimeCoordinate], on grid: WaterGrid)
    -> [MaritimeCoordinate]
  {
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

  private static func rounded(_ path: [MaritimeCoordinate], on grid: WaterGrid)
    -> [MaritimeCoordinate]
  {
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

  private static func pathLength(_ path: [MaritimeCoordinate]) -> Double {
    zip(path, path.dropFirst()).map(MaritimeGeometry.distance).reduce(0, +)
  }

  private static func join<S: Sequence>(_ sections: S) -> [MaritimeCoordinate]
  where S.Element: Sequence, S.Element.Element == MaritimeCoordinate {
    var result: [MaritimeCoordinate] = []
    for section in sections {
      for coordinate in section
      where result.last.map({ MaritimeGeometry.distance($0, coordinate) >= 1 }) ?? true {
        result.append(coordinate)
      }
    }
    return result
  }
}
