import Foundation

/// Plans deterministic, offline, illustrative water routes.
///
/// MaritimeRouteKit is not a navigation system. Its geometric routes ignore
/// depth, shipping lanes, traffic rules, tides, weather, restrictions, lock
/// operations, and vessel characteristics.
public actor MaritimeRoutePlanner {
  private var waterWorld: WaterWorld?
  private var routeWorkers: [WaterWorldWorker] = []
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
            inputIndex: index, stop: stop, status: .invalidCoordinate,
            normalizedCoordinate: nil, snapDistanceMeters: nil))
        nodes.append(nil)
        diagnostics.append(
          MaritimeRouteDiagnostic(
            id: "invalid-stop-\(index)", kind: .invalidCoordinate, stopIndex: index,
            message: "Stop \(index + 1) has a non-finite or out-of-range coordinate."))
        continue
      }

      guard let node = world.place(stop.coordinate, maximumSnapDistance: 25_000) else {
        placements.append(
          MaritimeStopPlacement(
            inputIndex: index, stop: stop, status: .noNavigableWaterWithin25Kilometers,
            normalizedCoordinate: nil, snapDistanceMeters: nil))
        nodes.append(nil)
        diagnostics.append(
          MaritimeRouteDiagnostic(
            id: "unplaceable-stop-\(index)", kind: .stopCannotBePlaced, stopIndex: index,
            message:
              "No ocean-connected water represented by the bundled data lies within 25 km of \(stop.title)."
          ))
        continue
      }

      nodes.append(node)
      placements.append(
        MaritimeStopPlacement(
          inputIndex: index, stop: stop, status: .placed,
          normalizedCoordinate: node.coordinate, snapDistanceMeters: node.snapDistance))
    }

    let legCount = max(0, stops.count - 1)
    var coordinatesByLeg = [[MaritimeCoordinate]?](repeating: nil, count: legCount)
    var work: [LegWork] = []
    for index in 0..<legCount {
      guard let start = nodes[index], let end = nodes[index + 1] else { continue }
      if MaritimeGeometry.distance(start.coordinate, end.coordinate) < 1 {
        coordinatesByLeg[index] = [start.coordinate]
      } else {
        work.append(LegWork(index: index, start: start, end: end))
      }
    }
    for result in await route(work) {
      coordinatesByLeg[result.index] = result.coordinates
    }

    var legs: [MaritimeRouteLeg] = []
    for index in 0..<legCount {
      guard nodes[index] != nil, nodes[index + 1] != nil else {
        diagnostics.append(
          MaritimeRouteDiagnostic(
            id: "unroutable-leg-\(index)", kind: .legCannotBeRouted, legStartIndex: index,
            message: "Leg \(index + 1) was omitted because one or both stops could not be placed."))
        continue
      }
      guard let coordinates = coordinatesByLeg[index] else {
        diagnostics.append(
          MaritimeRouteDiagnostic(
            id: "unroutable-leg-\(index)", kind: .legCannotBeRouted, legStartIndex: index,
            message:
              "No water-safe route was found for \(stops[index].title)–\(stops[index + 1].title)."))
        continue
      }
      legs.append(
        MaritimeRouteLeg(
          id: "leg-\(index)-\(stops[index].id)-\(stops[index + 1].id)", startIndex: index,
          endIndex: index + 1, startStopID: stops[index].id, endStopID: stops[index + 1].id,
          coordinates: coordinates))
    }

    return MaritimeRouteResult(placements: placements, legs: legs, diagnostics: diagnostics)
  }

  private func loadedWorld() throws -> WaterWorld {
    if let waterWorld { return waterWorld }
    if dataLoadFailed { throw CocoaError(.fileReadCorruptFile) }
    do {
      let loaded = try WaterWorld()
      waterWorld = loaded
      routeWorkers = [
        WaterWorldWorker(resource: loaded.resource),
        WaterWorldWorker(resource: loaded.resource),
      ]
      return loaded
    } catch {
      dataLoadFailed = true
      throw error
    }
  }

  private func route(_ work: [LegWork]) async -> [LegWorkResult] {
    guard !work.isEmpty else { return [] }
    let workerCount = min(routeWorkers.count, work.count)
    return await withTaskGroup(of: [LegWorkResult].self) { group in
      for workerIndex in 0..<workerCount {
        let worker = routeWorkers[workerIndex]
        let assigned = work.enumerated().compactMap { offset, item in
          offset % workerCount == workerIndex ? item : nil
        }
        group.addTask {
          var results: [LegWorkResult] = []
          results.reserveCapacity(assigned.count)
          for item in assigned {
            results.append(await worker.route(item))
          }
          return results
        }
      }
      var results: [LegWorkResult] = []
      for await batch in group { results.append(contentsOf: batch) }
      return results.sorted { $0.index < $1.index }
    }
  }

  private func dataUnavailableResult(stops: [MaritimeRouteStop], error: Error)
    -> MaritimeRouteResult
  {
    MaritimeRouteResult(
      placements: stops.enumerated().map { index, stop in
        MaritimeStopPlacement(
          inputIndex: index, stop: stop,
          status: MaritimeGeometry.isValid(stop.coordinate)
            ? .noNavigableWaterWithin25Kilometers : .invalidCoordinate,
          normalizedCoordinate: nil, snapDistanceMeters: nil)
      },
      legs: [],
      diagnostics: [
        MaritimeRouteDiagnostic(
          id: "routing-data-unavailable", kind: .routingDataUnavailable,
          message: "The bundled water dataset could not be loaded: \(error.localizedDescription)")
      ])
  }
}

private struct LegWork: Sendable {
  let index: Int
  let start: PlacedWaterNode
  let end: PlacedWaterNode
}

private struct LegWorkResult: Sendable {
  let index: Int
  let coordinates: [MaritimeCoordinate]?
}

private actor WaterWorldWorker {
  private let world: WaterWorld

  init(resource: WorldRouteResource) {
    world = WaterWorld(resource: resource)
  }

  func route(_ work: LegWork) -> LegWorkResult {
    LegWorkResult(
      index: work.index,
      coordinates: world.route(from: work.start, to: work.end)
    )
  }
}

struct PlacedWaterNode: Sendable {
  let coordinate: MaritimeCoordinate
  let snapDistance: Double
  let gridIndex: Int
  let cell: WaterGrid.Cell
}

/// Unified worldwide graph router. Mutable buffers are isolated by
/// `MaritimeRoutePlanner`, while tests may construct a world serially.
final class WaterWorld: @unchecked Sendable {
  private struct Access {
    let graphNode: Int
    let pathFromEndpoint: [MaritimeCoordinate]
    let cost: Double
  }

  private struct GraphFrontier: Comparable {
    let estimate: Double
    let cost: Double
    let node: Int
    let serial: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
      if lhs.estimate != rhs.estimate { return lhs.estimate < rhs.estimate }
      if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
      if lhs.node != rhs.node { return lhs.node < rhs.node }
      return lhs.serial < rhs.serial
    }
  }

  private struct LocalFrontier: Comparable {
    let cost: Double
    let index: Int
    let serial: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
      if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
      if lhs.index != rhs.index { return lhs.index < rhs.index }
      return lhs.serial < rhs.serial
    }
  }

  private struct RouteCacheKey: Hashable {
    let startGrid: Int
    let startCell: Int
    let startLatitude: UInt64
    let startLongitude: UInt64
    let endGrid: Int
    let endCell: Int
    let endLatitude: UInt64
    let endLongitude: UInt64
  }

  let resource: WorldRouteResource
  let grids: [WaterGrid]
  let globalGridIndex: Int

  private var graphCosts: [Double]
  private var graphParents: [Int]
  private var graphParentEdges: [Int]
  private var graphRoots: [Int]
  private var graphGenerations: [UInt32]
  private var graphGeneration: UInt32 = 0
  private var routeCache: [RouteCacheKey: [MaritimeCoordinate]] = [:]
  private var routeCacheOrder: [RouteCacheKey] = []

  convenience init() throws {
    try self.init(resource: WorldRouteResource())
  }

  init(resource: WorldRouteResource) {
    let grids = resource.metadata.grids.enumerated().map {
      WaterGrid(metadata: $0.element, gridIndex: $0.offset, resource: resource)
    }
    let globals = grids.indices.filter { grids[$0].isGlobal }
    precondition(globals.count == 1)
    let global = globals[0]
    self.resource = resource
    self.grids = grids
    self.globalGridIndex = global
    self.graphCosts = Array(repeating: .infinity, count: resource.graphNodeCount)
    self.graphParents = Array(repeating: -1, count: resource.graphNodeCount)
    self.graphParentEdges = Array(repeating: -1, count: resource.graphNodeCount)
    self.graphRoots = Array(repeating: -1, count: resource.graphNodeCount)
    self.graphGenerations = Array(repeating: 0, count: resource.graphNodeCount)
  }

  func place(_ coordinate: MaritimeCoordinate, maximumSnapDistance: Double) -> PlacedWaterNode? {
    var best: PlacedWaterNode?
    for (index, grid) in grids.enumerated() where grid.contains(coordinate) {
      if let cell = grid.cell(for: coordinate), grid.isNavigable(cell) {
        let candidate = PlacedWaterNode(
          coordinate: coordinate, snapDistance: 0, gridIndex: index, cell: cell)
        if isBetterPlacement(candidate, than: best) { best = candidate }
        continue
      }
      let searchDistance = min(maximumSnapDistance, best?.snapDistance ?? maximumSnapDistance)
      guard searchDistance > 0 else { continue }
      guard
        let (cell, distance) = grid.nearestNavigable(
          to: coordinate, maximumDistance: searchDistance)
      else { continue }
      let candidate = PlacedWaterNode(
        coordinate: grid.coordinate(for: cell), snapDistance: distance,
        gridIndex: index, cell: cell)
      if isBetterPlacement(candidate, than: best) { best = candidate }
    }
    return best
  }

  func route(from start: PlacedWaterNode, to end: PlacedWaterNode) -> [MaritimeCoordinate]? {
    let key = cacheKey(from: start, to: end)
    if let cached = routeCache[key] { return cached }

    if start.gridIndex == end.gridIndex,
      let startTile = grids[start.gridIndex].tileIndex(for: start.cell),
      startTile == grids[end.gridIndex].tileIndex(for: end.cell),
      let local = localPath(
        on: grids[start.gridIndex], from: start.coordinate, startCell: start.cell,
        to: end.coordinate, goalCell: end.cell, tileIndex: startTile)
    {
      return cache(local, for: key)
    }

    guard let starts = accesses(for: start), !starts.isEmpty,
      let ends = accesses(for: end), !ends.isEmpty,
      let graphPath = graphPath(from: starts, to: ends)
    else { return nil }
    let simplified = simplifyAcrossAvailableGrids(graphPath)
    guard simplified.count > 1, validate(simplified) else { return nil }
    return cache(simplified, for: key)
  }

  func isNavigableSegment(from start: MaritimeCoordinate, to end: MaritimeCoordinate) -> Bool {
    let candidates = grids.filter { $0.contains(start) && $0.contains(end) }
      .sorted {
        if $0.metadata.step != $1.metadata.step { return $0.metadata.step < $1.metadata.step }
        return $0.gridIndex < $1.gridIndex
      }
    guard let finest = candidates.first else { return false }
    return finest.segmentIsNavigable(from: start, to: end)
  }

  func hasGraphAccess(_ node: PlacedWaterNode) -> Bool {
    accesses(for: node)?.isEmpty == false
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

  private func accesses(for endpoint: PlacedWaterNode) -> [Access]? {
    let grid = grids[endpoint.gridIndex]
    guard let tileIndex = grid.tileIndex(for: endpoint.cell),
      let candidateNodes = resource.nodesByTile[tileIndex], !candidateNodes.isEmpty
    else { return nil }
    let candidates = Dictionary(
      uniqueKeysWithValues: candidateNodes.compactMap { nodeIndex -> (Int, Int)? in
        let node = resource.node(at: nodeIndex)
        guard node.gridIndex == endpoint.gridIndex else { return nil }
        return (node.linearCell, nodeIndex)
      })
    guard !candidates.isEmpty else { return nil }

    let searches = localPaths(
      on: grid, from: endpoint.coordinate, startCell: endpoint.cell,
      toLinearCells: candidates, tileIndex: tileIndex, maximumResults: 4)
    return searches.map {
      Access(graphNode: $0.node, pathFromEndpoint: $0.path, cost: $0.cost)
    }
  }

  private func graphPath(from starts: [Access], to ends: [Access]) -> [MaritimeCoordinate]? {
    beginGraphSearch()
    var targetByNode: [Int: (index: Int, cost: Double)] = [:]
    for (index, access) in ends.enumerated() {
      if let current = targetByNode[access.graphNode], current.cost <= access.cost { continue }
      targetByNode[access.graphNode] = (index, access.cost)
    }

    var frontier = PriorityQueue<GraphFrontier>()
    var serial = 0
    for (index, access) in starts.enumerated().sorted(by: {
      $0.element.graphNode < $1.element.graphNode
    }) {
      let node = access.graphNode
      if graphGenerations[node] == graphGeneration, graphCosts[node] <= access.cost { continue }
      graphGenerations[node] = graphGeneration
      graphCosts[node] = access.cost
      graphParents[node] = -1
      graphParentEdges[node] = -1
      graphRoots[node] = index
      let estimate = access.cost + graphHeuristic(node: node, ends: ends)
      frontier.push(
        GraphFrontier(estimate: estimate, cost: access.cost, node: node, serial: serial))
      serial += 1
    }

    var bestTarget: (node: Int, endIndex: Int, total: Double)?
    while let current = frontier.pop() {
      guard graphGenerations[current.node] == graphGeneration,
        graphCosts[current.node] == current.cost
      else { continue }
      if let bestTarget, current.estimate >= bestTarget.total { break }
      if let target = targetByNode[current.node] {
        let total = current.cost + target.cost
        if bestTarget == nil || total < bestTarget!.total
          || (total == bestTarget!.total && current.node < bestTarget!.node)
        {
          bestTarget = (current.node, target.index, total)
        }
      }

      for edgeIndex in resource.outgoingEdgeRange(for: current.node) {
        let edge = resource.edge(at: edgeIndex)
        let nextCost = current.cost + edge.cost
        if graphGenerations[edge.target] == graphGeneration,
          graphCosts[edge.target] <= nextCost
        {
          continue
        }
        graphGenerations[edge.target] = graphGeneration
        graphCosts[edge.target] = nextCost
        graphParents[edge.target] = current.node
        graphParentEdges[edge.target] = edgeIndex
        graphRoots[edge.target] = graphRoots[current.node]
        let estimate = nextCost + graphHeuristic(node: edge.target, ends: ends)
        frontier.push(
          GraphFrontier(estimate: estimate, cost: nextCost, node: edge.target, serial: serial))
        serial += 1
      }
    }
    guard let target = bestTarget else { return nil }

    var reversedNodes = [target.node]
    var reversedEdges: [Int] = []
    var node = target.node
    while graphParents[node] >= 0 {
      reversedEdges.append(graphParentEdges[node])
      node = graphParents[node]
      reversedNodes.append(node)
    }
    guard starts.indices.contains(graphRoots[target.node]), ends.indices.contains(target.endIndex)
    else {
      return nil
    }
    let nodes = reversedNodes.reversed()
    let edges = reversedEdges.reversed()
    var sections: [[MaritimeCoordinate]] = [starts[graphRoots[target.node]].pathFromEndpoint]
    for (pair, edgeIndex) in zip(zip(nodes, nodes.dropFirst()), edges) {
      let first = resource.node(at: pair.0)
      let second = resource.node(at: pair.1)
      let firstGrid = grids[first.gridIndex]
      let firstCell = WaterGrid.Cell(
        row: first.linearCell / firstGrid.metadata.columns,
        column: first.linearCell % firstGrid.metadata.columns)
      let secondGrid = grids[second.gridIndex]
      let secondCell = WaterGrid.Cell(
        row: second.linearCell / secondGrid.metadata.columns,
        column: second.linearCell % secondGrid.metadata.columns)
      let firstCoordinate = firstGrid.coordinate(for: firstCell)
      let secondCoordinate = secondGrid.coordinate(for: secondCell)
      let edge = resource.edge(at: edgeIndex)
      if let tile = edge.tileContext, first.gridIndex == second.gridIndex {
        guard
          let section = localPath(
            on: firstGrid, from: firstCoordinate, startCell: firstCell,
            to: secondCoordinate, goalCell: secondCell, tileIndex: tile)
        else { return nil }
        sections.append(section)
      } else if first.gridIndex == second.gridIndex,
        !isNavigableSegment(from: firstCoordinate, to: secondCoordinate),
        let tile = firstGrid.tileIndex(for: firstCell),
        tile == secondGrid.tileIndex(for: secondCell)
      {
        // The build-time raster proof is deliberately cheap. If the finer
        // runtime sampler sees a thin raster corner that it missed, reconstruct
        // the already-selected edge locally instead of accepting or dropping it.
        guard
          let section = localPath(
            on: firstGrid, from: firstCoordinate, startCell: firstCell,
            to: secondCoordinate, goalCell: secondCell, tileIndex: tile)
        else { return nil }
        sections.append(section)
      } else {
        sections.append([firstCoordinate, secondCoordinate])
      }
    }
    sections.append(Array(ends[target.endIndex].pathFromEndpoint.reversed()))
    let joined = Self.join(sections)
    return validate(joined) ? joined : nil
  }

  private func graphHeuristic(node: Int, ends: [Access]) -> Double {
    let coordinate = graphCoordinate(node)
    return ends.map {
      MaritimeGeometry.distance(coordinate, graphCoordinate($0.graphNode)) + $0.cost
    }.min() ?? .infinity
  }

  private func graphCoordinate(_ nodeIndex: Int) -> MaritimeCoordinate {
    let node = resource.node(at: nodeIndex)
    let grid = grids[node.gridIndex]
    return grid.coordinate(
      for: WaterGrid.Cell(
        row: node.linearCell / grid.metadata.columns,
        column: node.linearCell % grid.metadata.columns))
  }

  private func beginGraphSearch() {
    graphGeneration &+= 1
    if graphGeneration == 0 {
      graphGenerations = Array(repeating: 0, count: graphGenerations.count)
      graphGeneration = 1
    }
  }

  private func localPaths(
    on grid: WaterGrid,
    from startCoordinate: MaritimeCoordinate,
    startCell: WaterGrid.Cell,
    toLinearCells targets: [Int: Int],
    tileIndex: Int,
    maximumResults: Int
  ) -> [(node: Int, path: [MaritimeCoordinate], cost: Double)] {
    let tile = resource.tiles[tileIndex]
    guard tile.gridIndex == grid.gridIndex else { return [] }
    let firstRow = tile.tileRow * resource.metadata.tileSize
    let firstColumn = tile.tileColumn * resource.metadata.tileSize
    let width = tile.columns
    let height = tile.rows
    guard (firstRow..<(firstRow + height)).contains(startCell.row),
      (firstColumn..<(firstColumn + width)).contains(startCell.column)
    else { return [] }
    let startIndex = (startCell.row - firstRow) * width + startCell.column - firstColumn
    var costs = Array(repeating: Double.infinity, count: width * height)
    var parents = Array(repeating: -1, count: width * height)
    var frontier = PriorityQueue<LocalFrontier>()
    var serial = 0
    costs[startIndex] = MaritimeGeometry.distance(startCoordinate, grid.coordinate(for: startCell))
    frontier.push(LocalFrontier(cost: costs[startIndex], index: startIndex, serial: serial))
    serial += 1
    var results: [(node: Int, path: [MaritimeCoordinate], cost: Double)] = []
    let directions = [
      (-1, 0), (-1, 1), (0, 1), (1, 1),
      (1, 0), (1, -1), (0, -1), (-1, -1),
    ]

    while let current = frontier.pop(), results.count < maximumResults {
      guard costs[current.index] == current.cost else { continue }
      let local = localCell(
        current.index, width: width, firstRow: firstRow, firstColumn: firstColumn)
      let linear = local.row * grid.metadata.columns + local.column
      if let graphNode = targets[linear] {
        let cells = reconstructLocalCells(
          goalIndex: current.index, parents: parents, width: width,
          firstRow: firstRow, firstColumn: firstColumn)
        let path = coordinates(from: startCoordinate, cells: cells, on: grid)
        results.append((graphNode, simplifyAcrossAvailableGrids(path), current.cost))
      }
      for offset in directions {
        let nextRow = local.row + offset.0
        let nextColumn = local.column + offset.1
        guard (firstRow..<(firstRow + height)).contains(nextRow),
          (firstColumn..<(firstColumn + width)).contains(nextColumn)
        else { continue }
        let nextCell = WaterGrid.Cell(row: nextRow, column: nextColumn)
        guard grid.isNavigable(nextCell) else { continue }
        if offset.0 != 0, offset.1 != 0,
          !grid.isNavigable(WaterGrid.Cell(row: local.row + offset.0, column: local.column))
            || !grid.isNavigable(WaterGrid.Cell(row: local.row, column: local.column + offset.1))
        {
          continue
        }
        let nextIndex = (nextRow - firstRow) * width + nextColumn - firstColumn
        let step = MaritimeGeometry.distance(
          grid.coordinate(for: local), grid.coordinate(for: nextCell))
        let nextCost = current.cost + step * (1 + grid.shorePenalty(at: nextCell))
        guard nextCost < costs[nextIndex] else { continue }
        costs[nextIndex] = nextCost
        parents[nextIndex] = current.index
        frontier.push(LocalFrontier(cost: nextCost, index: nextIndex, serial: serial))
        serial += 1
      }
    }
    return results
  }

  private func localPath(
    on grid: WaterGrid,
    from startCoordinate: MaritimeCoordinate,
    startCell: WaterGrid.Cell,
    to endCoordinate: MaritimeCoordinate,
    goalCell: WaterGrid.Cell,
    tileIndex: Int
  ) -> [MaritimeCoordinate]? {
    if isNavigableSegment(from: startCoordinate, to: endCoordinate) {
      return [startCoordinate, endCoordinate]
    }
    let linear = goalCell.row * grid.metadata.columns + goalCell.column
    guard
      let result = localPaths(
        on: grid, from: startCoordinate, startCell: startCell,
        toLinearCells: [linear: 0], tileIndex: tileIndex, maximumResults: 1
      ).first
    else { return nil }
    var path = result.path
    if let last = path.last, MaritimeGeometry.distance(last, endCoordinate) >= 1 {
      guard grid.segmentIsNavigable(from: last, to: endCoordinate) else { return nil }
      path.append(endCoordinate)
    }
    return validate(path) ? path : nil
  }

  private func localCell(_ index: Int, width: Int, firstRow: Int, firstColumn: Int)
    -> WaterGrid.Cell
  {
    let position = index.quotientAndRemainder(dividingBy: width)
    return WaterGrid.Cell(
      row: firstRow + position.quotient, column: firstColumn + position.remainder)
  }

  private func reconstructLocalCells(
    goalIndex: Int, parents: [Int], width: Int, firstRow: Int, firstColumn: Int
  ) -> [WaterGrid.Cell] {
    var result: [WaterGrid.Cell] = []
    var index = goalIndex
    while index >= 0 {
      result.append(localCell(index, width: width, firstRow: firstRow, firstColumn: firstColumn))
      index = parents[index]
    }
    return result.reversed()
  }

  private func coordinates(
    from start: MaritimeCoordinate, cells: [WaterGrid.Cell], on grid: WaterGrid
  ) -> [MaritimeCoordinate] {
    var result = [start]
    for cell in cells {
      let coordinate = grid.coordinate(for: cell)
      if result.last.map({ MaritimeGeometry.distance($0, coordinate) >= 1 }) ?? true {
        result.append(coordinate)
      }
    }
    return result
  }

  private func simplifyAcrossAvailableGrids(_ path: [MaritimeCoordinate])
    -> [MaritimeCoordinate]
  {
    guard path.count > 2 else { return path }
    var result = [path[0]]
    var index = 0
    while index < path.count - 1 {
      var candidate = min(path.count - 1, index + 192)
      while candidate > index + 1,
        !isNavigableSegment(from: path[index], to: path[candidate])
      { candidate -= 1 }
      result.append(path[candidate])
      index = candidate
    }
    return result
  }

  private func simplify(_ path: [MaritimeCoordinate], on grid: WaterGrid)
    -> [MaritimeCoordinate]
  {
    guard path.count > 2 else { return path }
    var result = [path[0]]
    var index = 0
    while index < path.count - 1 {
      var candidate = min(path.count - 1, index + 192)
      while candidate > index + 1,
        !grid.segmentIsNavigable(from: path[index], to: path[candidate])
      { candidate -= 1 }
      result.append(path[candidate])
      index = candidate
    }
    return result
  }

  private func validate(_ path: [MaritimeCoordinate]) -> Bool {
    zip(path, path.dropFirst()).allSatisfy(isNavigableSegment)
  }

  private func cacheKey(from start: PlacedWaterNode, to end: PlacedWaterNode) -> RouteCacheKey {
    RouteCacheKey(
      startGrid: start.gridIndex,
      startCell: start.cell.row * grids[start.gridIndex].metadata.columns + start.cell.column,
      startLatitude: start.coordinate.latitude.bitPattern,
      startLongitude: start.coordinate.longitude.bitPattern,
      endGrid: end.gridIndex,
      endCell: end.cell.row * grids[end.gridIndex].metadata.columns + end.cell.column,
      endLatitude: end.coordinate.latitude.bitPattern,
      endLongitude: end.coordinate.longitude.bitPattern)
  }

  private func cache(_ path: [MaritimeCoordinate], for key: RouteCacheKey)
    -> [MaritimeCoordinate]
  {
    if routeCache[key] == nil {
      routeCacheOrder.append(key)
      if routeCacheOrder.count > 128 {
        routeCache.removeValue(forKey: routeCacheOrder.removeFirst())
      }
    }
    routeCache[key] = path
    return path
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
