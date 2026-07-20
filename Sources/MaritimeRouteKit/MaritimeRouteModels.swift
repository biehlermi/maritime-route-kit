/// A latitude/longitude pair used by MaritimeRouteKit.
///
/// Coordinates are validated when they are passed to ``MaritimeRoutePlanner``.
///
/// ```swift
/// let coordinate = MaritimeCoordinate(latitude: 37.80, longitude: -122.42)
/// ```
public struct MaritimeCoordinate: Hashable, Sendable {
  /// The latitude in degrees.
  public let latitude: Double
  /// The longitude in degrees.
  public let longitude: Double

  /// Creates a new maritime coordinate.
  ///
  /// - Parameters:
  ///   - latitude: The latitude in degrees.
  ///   - longitude: The longitude in degrees.
  public init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }
}

/// One call in an ordered itinerary.
///
/// `id` identifies the itinerary call, not a port catalog entry. Give repeated
/// visits different IDs so that they remain distinct calls.
///
/// ```swift
/// let stop = MaritimeRouteStop(
///   id: "sf-1",
///   title: "San Francisco",
///   coordinate: MaritimeCoordinate(latitude: 37.80, longitude: -122.42)
/// )
/// ```
public struct MaritimeRouteStop: Identifiable, Hashable, Sendable {
  /// The unique identifier for this itinerary call.
  public let id: String
  /// The display title of the stop.
  public let title: String
  /// The geographic coordinate of the stop.
  public let coordinate: MaritimeCoordinate

  /// Creates a new route stop.
  ///
  /// - Parameters:
  ///   - id: The unique identifier for this itinerary call.
  ///   - title: The display title of the stop.
  ///   - coordinate: The requested coordinate.
  public init(id: String, title: String, coordinate: MaritimeCoordinate) {
    self.id = id
    self.title = title
    self.coordinate = coordinate
  }
}

/// The status of placing an input stop onto the navigable water network.
public enum MaritimeStopPlacementStatus: String, Hashable, Sendable {
  /// The stop was successfully placed on water.
  case placed
  /// The provided coordinate was invalid or out of bounds.
  case invalidCoordinate
  /// No navigable water could be found within the plan's maximum snap distance.
  case noNavigableWater
  /// Placement could not be attempted because the bundled routing data was unavailable.
  case routingDataUnavailable
}

/// The normalized water placement corresponding to one input stop.
///
/// A placement associates a valid ``MaritimeRouteStop`` with its actual location
/// on the navigable water graph.
public struct MaritimeStopPlacement: Identifiable, Hashable, Sendable {
  /// The unique identifier of the original stop.
  public var id: String { stop.id }
  /// The 0-based index of the original stop in the input itinerary.
  public let inputIndex: Int
  /// The original input stop.
  public let stop: MaritimeRouteStop
  /// The outcome of attempting to place the stop.
  public let status: MaritimeStopPlacementStatus
  /// The adjusted coordinate on the water graph, if placement was successful.
  public let normalizedCoordinate: MaritimeCoordinate?
  /// The distance from the input coordinate to the water graph, in meters.
  public let snapDistanceMeters: Double?

  /// Creates a new placement.
  ///
  /// - Parameters:
  ///   - inputIndex: The 0-based index of the original stop in the input itinerary.
  ///   - stop: The original input stop.
  ///   - status: The outcome of attempting to place the stop.
  ///   - normalizedCoordinate: The adjusted coordinate on the water graph, if successful.
  ///   - snapDistanceMeters: The distance from the input coordinate to the water graph.
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

/// The type of issue encountered during route planning.
public enum MaritimeRouteDiagnosticKind: String, Hashable, Sendable {
  /// A coordinate provided for a stop was invalid.
  case invalidCoordinate
  /// A stop could not be snapped to the water graph.
  case stopCannotBePlaced
  /// A route leg between two placed stops could not be found.
  case legCannotBeRouted
  /// The bundled routing data could not be loaded.
  case routingDataUnavailable
}

/// A structured explanation for a stop or leg omitted from the route.
public struct MaritimeRouteDiagnostic: Identifiable, Hashable, Sendable {
  /// The unique identifier for this diagnostic.
  public let id: String
  /// The kind of diagnostic.
  public let kind: MaritimeRouteDiagnosticKind
  /// The optional index of the affected stop.
  public let stopIndex: Int?
  /// The optional starting index of the affected leg.
  public let legStartIndex: Int?
  /// A human-readable message describing the issue.
  public let message: String

  /// Creates a new route diagnostic.
  ///
  /// - Parameters:
  ///   - id: The unique identifier for this diagnostic.
  ///   - kind: The kind of diagnostic.
  ///   - stopIndex: The optional index of the affected stop.
  ///   - legStartIndex: The optional starting index of the affected leg.
  ///   - message: A human-readable message describing the issue.
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
  /// The unique identifier for this leg.
  public let id: String
  /// The starting stop's index in the input itinerary.
  public let startIndex: Int
  /// The ending stop's index in the input itinerary.
  public let endIndex: Int
  /// The identifier of the starting stop.
  public let startStopID: String
  /// The identifier of the ending stop.
  public let endStopID: String
  /// The sequence of coordinates forming the route.
  public let coordinates: [MaritimeCoordinate]

  /// A Boolean value indicating whether the leg has fewer than two coordinates.
  public var isTrivial: Bool { coordinates.count < 2 }

  /// The length of the route geometry, in meters.
  public var distanceInMeters: Double {
    zip(coordinates, coordinates.dropFirst()).map(MaritimeGeometry.distance).reduce(0, +)
  }

  /// The length of the route geometry, in nautical miles.
  public var distanceInNauticalMiles: Double { distanceInMeters / 1_852 }

  /// Creates a new route leg.
  ///
  /// - Parameters:
  ///   - id: The unique identifier for this leg.
  ///   - startIndex: The starting stop's index.
  ///   - endIndex: The ending stop's index.
  ///   - startStopID: The identifier of the starting stop.
  ///   - endStopID: The identifier of the ending stop.
  ///   - coordinates: The sequence of coordinates forming the route.
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

/// A screen-oriented direction marker for a successful route leg.
///
/// Apply `rotationRadians` to an east-pointing symbol. Positive values rotate
/// clockwise in MapKit's screen projection, including across the antimeridian.
public struct MaritimeRouteArrow: Identifiable, Hashable, Sendable {
  /// The identifier of the route leg represented by this arrow.
  public let id: String
  /// The coordinate at the midpoint of the route leg's traveled distance.
  public let coordinate: MaritimeCoordinate
  /// The clockwise rotation from east, in radians.
  public let rotationRadians: Double

  /// Creates a route direction marker.
  ///
  /// - Parameters:
  ///   - id: The identifier of the represented route leg.
  ///   - coordinate: The marker coordinate.
  ///   - rotationRadians: The clockwise rotation from east, in radians.
  public init(id: String, coordinate: MaritimeCoordinate, rotationRadians: Double) {
    self.id = id
    self.coordinate = coordinate
    self.rotationRadians = rotationRadians
  }
}

/// The complete deterministic result for an itinerary.
///
/// This result is illustrative and must never be used for navigation. It does
/// not account for shipping lanes, depth, tides, weather, traffic separation
/// schemes, lock operations, restricted waters, or vessel characteristics.
public struct MaritimeRouteResult: Hashable, Sendable {
  /// The placement results for all requested stops.
  public let placements: [MaritimeStopPlacement]
  /// The successfully routed segments between consecutive placed stops.
  public let legs: [MaritimeRouteLeg]
  /// The issues preventing a complete route, if any.
  public let diagnostics: [MaritimeRouteDiagnostic]

  /// A Boolean value indicating whether planning reported no failures.
  ///
  /// This property is exactly equivalent to `diagnostics.isEmpty`. It does not
  /// indicate that the illustrative route is safe or suitable for navigation.
  public var isComplete: Bool { diagnostics.isEmpty }

  /// Antimeridian-safe, drawable polylines for all successful legs.
  ///
  /// Trivial legs are omitted. A leg crossing the antimeridian produces more
  /// than one polyline so that map renderers do not draw across the world.
  public var routePolylines: [[MaritimeCoordinate]] {
    legs.flatMap { MaritimeGeometry.splitAtAntimeridian($0.coordinates) }
      .filter { $0.count > 1 }
  }

  /// One screen-oriented midpoint arrow for each leg longer than 10 meters.
  public var routeArrows: [MaritimeRouteArrow] {
    legs.compactMap { leg in
      MaritimeGeometry.arrow(for: leg.coordinates).map {
        MaritimeRouteArrow(
          id: leg.id,
          coordinate: $0.coordinate,
          rotationRadians: $0.rotationRadians)
      }
    }
  }

  /// The combined length of all successfully routed legs, in meters.
  ///
  /// Check ``diagnostics`` before treating this value as the length of the
  /// complete requested itinerary because failed legs are not included.
  public var distanceInMeters: Double { legs.map(\.distanceInMeters).reduce(0, +) }

  /// The combined length of all successfully routed legs, in nautical miles.
  ///
  /// One nautical mile is exactly 1,852 meters.
  public var distanceInNauticalMiles: Double { distanceInMeters / 1_852 }

  /// Creates a new route result.
  ///
  /// - Parameters:
  ///   - placements: The placement results for all requested stops.
  ///   - legs: The successfully routed segments.
  ///   - diagnostics: The issues preventing a complete route, if any.
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
