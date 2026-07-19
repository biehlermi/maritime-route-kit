/// A latitude/longitude pair used by MaritimeRouteKit.
///
/// Coordinates are validated when they are passed to ``MaritimeRoutePlanner``.
public struct MaritimeCoordinate: Hashable, Sendable {
  public let latitude: Double
  public let longitude: Double

  public init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }
}

/// One call in an ordered itinerary.
///
/// `id` identifies the itinerary call, not a port catalog entry. Give repeated
/// visits different IDs so that they remain distinct calls.
public struct MaritimeRouteStop: Identifiable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let coordinate: MaritimeCoordinate

  public init(id: String, title: String, coordinate: MaritimeCoordinate) {
    self.id = id
    self.title = title
    self.coordinate = coordinate
  }
}

public enum MaritimeStopPlacementStatus: String, Hashable, Sendable {
  case placed
  case invalidCoordinate
  case noNavigableWaterWithin25Kilometers
}

/// The normalized water placement corresponding to one input stop.
public struct MaritimeStopPlacement: Identifiable, Hashable, Sendable {
  public var id: String { stop.id }
  public let inputIndex: Int
  public let stop: MaritimeRouteStop
  public let status: MaritimeStopPlacementStatus
  public let normalizedCoordinate: MaritimeCoordinate?
  public let snapDistanceMeters: Double?

  public init(
    inputIndex: Int,
    stop: MaritimeRouteStop,
    status: MaritimeStopPlacementStatus,
    normalizedCoordinate: MaritimeCoordinate?,
    snapDistanceMeters: Double?
  ) {
    self.inputIndex = inputIndex
    self.stop = stop
    self.status = status
    self.normalizedCoordinate = normalizedCoordinate
    self.snapDistanceMeters = snapDistanceMeters
  }
}

public enum MaritimeRouteDiagnosticKind: String, Hashable, Sendable {
  case invalidCoordinate
  case stopCannotBePlaced
  case legCannotBeRouted
  case routingDataUnavailable
}

/// A structured explanation for a stop or leg omitted from the route.
public struct MaritimeRouteDiagnostic: Identifiable, Hashable, Sendable {
  public let id: String
  public let kind: MaritimeRouteDiagnosticKind
  public let stopIndex: Int?
  public let legStartIndex: Int?
  public let message: String

  public init(
    id: String,
    kind: MaritimeRouteDiagnosticKind,
    stopIndex: Int? = nil,
    legStartIndex: Int? = nil,
    message: String
  ) {
    self.id = id
    self.kind = kind
    self.stopIndex = stopIndex
    self.legStartIndex = legStartIndex
    self.message = message
  }
}

/// The successfully planned geometry between two consecutive itinerary calls.
public struct MaritimeRouteLeg: Identifiable, Hashable, Sendable {
  public let id: String
  public let startIndex: Int
  public let endIndex: Int
  public let startStopID: String
  public let endStopID: String
  public let coordinates: [MaritimeCoordinate]

  public var isTrivial: Bool { coordinates.count < 2 }

  public init(
    id: String,
    startIndex: Int,
    endIndex: Int,
    startStopID: String,
    endStopID: String,
    coordinates: [MaritimeCoordinate]
  ) {
    self.id = id
    self.startIndex = startIndex
    self.endIndex = endIndex
    self.startStopID = startStopID
    self.endStopID = endStopID
    self.coordinates = coordinates
  }
}

/// The complete deterministic result for an itinerary.
///
/// This result is illustrative and must never be used for navigation. It does
/// not account for shipping lanes, depth, tides, weather, traffic separation
/// schemes, lock operations, restricted waters, or vessel characteristics.
public struct MaritimeRouteResult: Hashable, Sendable {
  public let placements: [MaritimeStopPlacement]
  public let legs: [MaritimeRouteLeg]
  public let diagnostics: [MaritimeRouteDiagnostic]

  public init(
    placements: [MaritimeStopPlacement],
    legs: [MaritimeRouteLeg],
    diagnostics: [MaritimeRouteDiagnostic]
  ) {
    self.placements = placements
    self.legs = legs
    self.diagnostics = diagnostics
  }
}
