import Foundation
import MapKit
import Testing

@testable import MaritimeRouteKit

@Suite("Maritime route planning", .serialized)
struct MaritimeRoutePlannerTests {
  @Test("One stop, repeated calls, and a same-location leg preserve order")
  func itinerarySemantics() async throws {
    let hamburg = stop("hamburg-1", "Hamburg", 53.535, 9.950)
    let repeatedHamburg = stop("hamburg-2", "Hamburg", 53.535, 9.950)
    let oneStop = await MaritimeRoutePlanner().plan(stops: [hamburg])
    #expect(oneStop.placements.map(\.stop.id) == ["hamburg-1"])
    #expect(oneStop.legs.isEmpty)
    #expect(oneStop.isComplete)

    let repeated = await MaritimeRoutePlanner().plan(stops: [hamburg, repeatedHamburg])
    #expect(repeated.placements.map(\.stop.id) == ["hamburg-1", "hamburg-2"])
    #expect(repeated.legs.count == 1)
    #expect(repeated.legs[0].isTrivial)
    #expect(repeated.legs[0].startIndex == 0)
    #expect(repeated.legs[0].endIndex == 1)
  }

  @Test("Invalid and deeply inland coordinates are diagnosed")
  func invalidAndInlandStops() async {
    let result = await MaritimeRoutePlanner().plan(stops: [
      stop("nan", "Invalid", .nan, 9),
      stop("berlin", "Berlin", 52.520, 13.405),
    ])
    #expect(result.placements[0].status == .invalidCoordinate)
    #expect(result.placements[1].status == .noNavigableWater)
    #expect(result.diagnostics.contains { $0.kind == .invalidCoordinate })
    #expect(result.diagnostics.contains { $0.kind == .stopCannotBePlaced })
    #expect(!result.isComplete)
  }

  @Test("A port coordinate slightly over land snaps to represented water")
  func coastalSnap() async throws {
    let result = await MaritimeRoutePlanner().plan(stops: [
      stop("geiranger", "Geiranger", 62.1015, 7.207)
    ])
    let placement = try #require(result.placements.first)
    #expect(placement.status == .placed)
    #expect(placement.normalizedCoordinate != nil)
    #expect((placement.snapDistanceMeters ?? 0) > 0)
    #expect((placement.snapDistanceMeters ?? .infinity) < 25_000)
  }

  @Test("The per-plan snap limit can reject land without rejecting represented water")
  func configurableSnapDistance() async throws {
    let planner = MaritimeRoutePlanner()
    let geiranger = stop("geiranger", "Geiranger", 62.1015, 7.207)
    let normal = await planner.plan(stops: [geiranger])
    let normalized = try #require(normal.placements.first?.normalizedCoordinate)
    #expect((normal.placements.first?.snapDistanceMeters ?? 0) > 0)

    let strict = await planner.plan(stops: [geiranger], maximumSnapDistanceMeters: 0)
    #expect(strict.placements.first?.status == .noNavigableWater)
    #expect(strict.diagnostics.contains { $0.kind == .stopCannotBePlaced })

    let representedWater = MaritimeRouteStop(
      id: "represented-water", title: "Represented Water", coordinate: normalized)
    let exact = await planner.plan(stops: [representedWater], maximumSnapDistanceMeters: 0)
    #expect(exact.placements.first?.status == .placed)
    #expect(exact.placements.first?.snapDistanceMeters == 0)
  }

  @Test("Hamburg routes down the Elbe to Bergen")
  func hamburgToBergen() async throws {
    let result = await MaritimeRoutePlanner().plan(stops: [
      stop("hamburg", "Hamburg", 53.535, 9.950),
      stop("bergen", "Bergen", 60.392, 5.323),
    ])
    let leg = try #require(result.legs.first)
    #expect(result.diagnostics.filter { $0.kind == .legCannotBeRouted }.isEmpty)
    #expect(leg.coordinates.count > 2)
    try assertEverySegmentIsWaterSafe(leg)
  }

  @Test("Hamburg routes down the Elbe and into Geirangerfjord")
  func hamburgToGeirangerfjord() async throws {
    let result = await MaritimeRoutePlanner().plan(stops: [
      stop("hamburg", "Hamburg", 53.535, 9.950),
      stop("geiranger", "Geiranger", 62.1015, 7.207),
    ])
    let leg = try #require(result.legs.first)
    #expect(result.diagnostics.filter { $0.kind == .legCannotBeRouted }.isEmpty)
    #expect(leg.coordinates.count > 4)
    try assertEverySegmentIsWaterSafe(leg)
  }

  @Test("A Baltic itinerary reaches Stockholm through the archipelago")
  func balticItinerary() async throws {
    let stops = [
      stop("kiel", "Kiel", 54.323, 10.139),
      stop("copenhagen", "Copenhagen", 55.690, 12.600),
      stop("stockholm", "Stockholm", 59.329, 18.069),
      stop("helsinki", "Helsinki", 60.170, 24.940),
      stop("tallinn", "Tallinn", 59.442, 24.754),
    ]
    let result = await MaritimeRoutePlanner().plan(stops: stops)
    #expect(result.placements.map(\.stop.id) == stops.map(\.id))
    #expect(result.placements.allSatisfy { $0.status == .placed })
    #expect(result.legs.count == stops.count - 1)
    for leg in result.legs { try assertEverySegmentIsWaterSafe(leg) }
  }

  @Test("The Mallorca–Barcelona–Suez–Dubai preview itinerary draws every leg")
  func suezPreviewItinerary() async throws {
    let stops = [
      stop("mallorca", "Mallorca", 39.5696, 2.6502),
      stop("barcelona", "Barcelona", 41.3851, 2.1734),
      stop("suez", "Suez Canal", 30.5852, 32.2654),
      stop("dubai", "Dubai", 25.2048, 55.2708),
    ]
    let result = await MaritimeRoutePlanner().plan(stops: stops)
    #expect(result.placements.allSatisfy { $0.status == .placed })
    try #require(result.legs.map(\.startIndex) == [0, 1, 2])
    #expect(result.diagnostics.filter { $0.kind == .legCannotBeRouted }.isEmpty)
    #expect(result.legs[1].coordinates.contains(where: isInsideSuezConnector))
    #expect(result.legs[2].coordinates.contains(where: isInsideSuezConnector))
    for leg in result.legs { try assertEverySegmentIsWaterSafe(leg) }
  }

  @Test("A Mediterranean-to-Gulf route selects the Suez connector without a canal stop")
  func automaticSuezPassage() async throws {
    let result = await MaritimeRoutePlanner().plan(stops: [
      stop("barcelona", "Barcelona", 41.3851, 2.1734),
      stop("dubai", "Dubai", 25.2048, 55.2708),
    ])
    let leg = try #require(result.legs.first)
    #expect(result.diagnostics.filter { $0.kind == .legCannotBeRouted }.isEmpty)
    #expect(leg.coordinates.contains(where: isInsideSuezConnector))
    #expect(pathLength(leg.coordinates) < 9_000_000)
    try assertEverySegmentIsWaterSafe(leg)
  }

  @Test("Suez supports entry, exit, and reverse-direction routing")
  func reverseSuezPassage() async throws {
    let stops = [
      stop("jeddah", "Jeddah", 21.4858, 39.1925),
      stop("suez", "Suez Canal", 30.5852, 32.2654),
      stop("alexandria", "Alexandria", 31.2001, 29.9187),
    ]
    let result = await MaritimeRoutePlanner().plan(stops: stops)
    #expect(result.legs.count == 2)
    #expect(result.legs.allSatisfy { $0.coordinates.contains(where: isInsideSuezConnector) })
    for leg in result.legs { try assertEverySegmentIsWaterSafe(leg) }
  }

  @Test("A Caribbean-to-Pacific itinerary enters and exits the Panama Canal")
  func panamaCanalItinerary() async throws {
    let stops = [
      stop("cartagena", "Cartagena", 10.3910, -75.4794),
      stop("panama", "Panama Canal", 9.1214, -79.8035),
      stop("puntarenas", "Puntarenas", 9.9763, -84.8384),
    ]
    let result = await MaritimeRoutePlanner().plan(stops: stops)
    #expect(result.placements.allSatisfy { $0.status == .placed })
    #expect(result.legs.count == 2)
    #expect(result.legs.allSatisfy { $0.coordinates.contains(where: isInsidePanamaConnector) })
    for leg in result.legs { try assertEverySegmentIsWaterSafe(leg) }
  }

  @Test("Panama is selected automatically in both directions")
  func automaticPanamaPassage() async throws {
    let cartagena = stop("cartagena", "Cartagena", 10.3910, -75.4794)
    let puntarenas = stop("puntarenas", "Puntarenas", 9.9763, -84.8384)
    let planner = MaritimeRoutePlanner()
    let eastToWest = await planner.plan(stops: [cartagena, puntarenas])
    let westToEast = await planner.plan(stops: [puntarenas, cartagena])

    for result in [eastToWest, westToEast] {
      let leg = try #require(result.legs.first)
      #expect(result.diagnostics.filter { $0.kind == .legCannotBeRouted }.isEmpty)
      #expect(leg.coordinates.contains(where: isInsidePanamaConnector))
      #expect(pathLength(leg.coordinates) < 2_500_000)
      try assertEverySegmentIsWaterSafe(leg)
    }
  }

  @Test("A northern-fjord itinerary routes between outer and inner Geirangerfjord")
  func geirangerfjordCalls() async throws {
    let stops = [
      stop("outer", "Storfjorden", 62.45, 5.72),
      stop("hellesylt", "Hellesylt", 62.0854, 6.8698),
      stop("geiranger", "Geiranger", 62.1015, 7.2070),
      stop("seven-sisters", "Seven Sisters", 62.1070, 7.0940),
    ]
    let result = await MaritimeRoutePlanner().plan(stops: stops)
    #expect(result.placements.allSatisfy { $0.status == .placed })
    #expect(result.legs.count == stops.count - 1)
    for leg in result.legs { try assertEverySegmentIsWaterSafe(leg) }
  }

  @Test("Fourteen Caribbean ports and islands produce thirteen ordered legs")
  func fourteenStopCaribbeanItinerary() async throws {
    let stops = caribbeanStops
    let result = await MaritimeRoutePlanner().plan(stops: stops)
    #expect(result.placements.map(\.stop.id) == stops.map(\.id))
    #expect(result.placements.allSatisfy { $0.status == .placed })
    #expect(result.legs.count == 13)
    #expect(result.diagnostics.filter { $0.kind == .legCannotBeRouted }.isEmpty)
    for leg in result.legs { try assertEverySegmentIsWaterSafe(leg) }
  }

  @Test("Bundled constrained resources are discovered without a Swift filename catalog")
  func dataDrivenWaterwayDiscovery() throws {
    let world = try WaterWorld()
    let connectors = world.grids.filter { $0.metadata.kind == "connector" }
    #expect(Set(connectors.map(\.metadata.name)) == ["panama", "suez"])
    #expect(connectors.allSatisfy { $0.gateways.count == 2 })
    #expect(world.grids.filter { $0.metadata.kind == "constrained" }.count >= 4)
    #expect(
      !world.isNavigableSegment(
        from: MaritimeCoordinate(latitude: 8.8875, longitude: -79.5125),
        to: MaritimeCoordinate(latitude: 8.862500000000011, longitude: -79.5375)
      ))
  }

  @Test("The single worldwide resource stays below 25 MiB and validates 600 WPI ports")
  func worldwideResourceAndPortCoverage() throws {
    let world = try WaterWorld()
    #expect(world.resource.installedByteCount <= 25 * 1_024 * 1_024)
    let url = try #require(Bundle.module.url(forResource: "worldwide_ports", withExtension: "json"))
    let catalog = try JSONDecoder().decode(WorldPortCatalog.self, from: Data(contentsOf: url))
    #expect(catalog.ports.count >= 500)
    var placedCount = 0
    var connectedCount = 0
    for port in catalog.ports {
      let coordinate = MaritimeCoordinate(latitude: port.latitude, longitude: port.longitude)
      guard let placement = world.place(coordinate, maximumSnapDistance: 25_000) else { continue }
      placedCount += 1
      if world.hasGraphAccess(placement) { connectedCount += 1 }
    }
    #expect(placedCount >= 500)
    #expect(connectedCount >= 500)
  }

  @Test("Planning is deterministic")
  func deterministic() async {
    let stops = [
      stop("hamburg", "Hamburg", 53.535, 9.950),
      stop("bergen", "Bergen", 60.392, 5.323),
    ]
    let planner = MaritimeRoutePlanner()
    let first = await planner.plan(stops: stops)
    let second = await planner.plan(stops: stops)
    #expect(first == second)
  }

  @Test("Planning crosses the antimeridian without an artificial seam")
  func antimeridianPlanning() async throws {
    let result = await MaritimeRoutePlanner().plan(stops: [
      stop("west", "West", 0, 179),
      stop("east", "East", 0, -179),
    ])
    let leg = try #require(result.legs.first)
    #expect(result.diagnostics.filter { $0.kind == .legCannotBeRouted }.isEmpty)
    #expect(MaritimeGeometry.splitAtAntimeridian(leg.coordinates).count == 2)
    try assertEverySegmentIsWaterSafe(leg)
  }

  @Test("Planning yields while called by the main actor")
  @MainActor
  func planningDoesNotBlockMainActor() async {
    let planner = MaritimeRoutePlanner()
    let task = Task {
      await planner.plan(stops: [
        stop("hamburg", "Hamburg", 53.535, 9.950),
        stop("geiranger", "Geiranger", 62.1015, 7.207),
      ])
    }
    await Task.yield()
    let markerSetAfterYield = true
    _ = await task.value
    #expect(markerSetAfterYield)
  }

  private func assertEverySegmentIsWaterSafe(_ leg: MaritimeRouteLeg) throws {
    let world = try WaterWorld()
    for (start, end) in zip(leg.coordinates, leg.coordinates.dropFirst()) {
      #expect(world.isNavigableSegment(from: start, to: end))
    }
  }
}

private struct WorldPortCatalog: Decodable {
  struct Port: Decodable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
  }

  let ports: [Port]
}

private let caribbeanStops = [
  stop("miami", "Miami", 25.7743, -80.1572),
  stop("nassau", "Nassau", 25.0781, -77.3385),
  stop("grand-turk", "Grand Turk", 21.4603, -71.1419),
  stop("san-juan", "San Juan", 18.4655, -66.1057),
  stop("st-thomas", "St. Thomas", 18.3405, -64.9307),
  stop("st-maarten", "St. Maarten", 18.0204, -63.0458),
  stop("antigua", "Antigua", 17.1212, -61.8440),
  stop("guadeloupe", "Guadeloupe", 16.2306, -61.5364),
  stop("dominica", "Dominica", 15.2967, -61.3870),
  stop("martinique", "Martinique", 14.6008, -61.0690),
  stop("st-lucia", "St. Lucia", 14.0101, -60.9990),
  stop("barbados", "Barbados", 13.1000, -59.6167),
  stop("grenada", "Grenada", 12.0500, -61.7500),
  stop("curacao", "Curaçao", 12.1084, -68.9335),
]

private func isInsideSuezConnector(_ coordinate: MaritimeCoordinate) -> Bool {
  (30.0...31.2).contains(coordinate.latitude)
    && (32.25...32.60).contains(coordinate.longitude)
}

private func isInsidePanamaConnector(_ coordinate: MaritimeCoordinate) -> Bool {
  (8.94...9.31).contains(coordinate.latitude)
    && (-79.93 ... -79.56).contains(coordinate.longitude)
}

private func pathLength(_ coordinates: [MaritimeCoordinate]) -> Double {
  zip(coordinates, coordinates.dropFirst()).map(MaritimeGeometry.distance).reduce(0, +)
}

@Suite("Map presentation")
struct MapPresentationTests {
  @Test("Completion is exactly equivalent to having no diagnostics")
  func completionStatus() {
    let complete = MaritimeRouteResult(placements: [], legs: [], diagnostics: [])
    let incomplete = MaritimeRouteResult(
      placements: [], legs: [],
      diagnostics: [
        MaritimeRouteDiagnostic(
          id: "failure", kind: .legCannotBeRouted, message: "A planning failure.")
      ])

    #expect(complete.isComplete)
    #expect(!incomplete.isComplete)
    #expect(complete.isComplete == complete.diagnostics.isEmpty)
    #expect(incomplete.isComplete == incomplete.diagnostics.isEmpty)
  }

  @Test("Antimeridian legs split without a world-spanning polyline")
  func antimeridianSplit() {
    let coordinates = [
      MaritimeCoordinate(latitude: 10, longitude: 179),
      MaritimeCoordinate(latitude: 10.5, longitude: -179),
    ]
    let parts = MaritimeGeometry.splitAtAntimeridian(coordinates)
    #expect(parts.count == 2)
    #expect(
      parts.allSatisfy { part in
        zip(part, part.dropFirst()).allSatisfy {
          abs($0.longitude - $1.longitude) <= 180
        }
      })
    let region = MaritimeMapViewport.region(for: coordinates)
    #expect((region?.span.longitudeDelta ?? 360) < 5)
  }

  @Test("One non-trivial leg creates one fixed-size arrow descriptor")
  func arrowCount() {
    let first = stop("a", "A", 54, 8)
    let second = stop("b", "B", 55, 9)
    let result = MaritimeRouteResult(
      placements: [
        MaritimeStopPlacement(
          inputIndex: 0, stop: first, status: .placed, normalizedCoordinate: first.coordinate,
          snapDistanceMeters: 0),
        MaritimeStopPlacement(
          inputIndex: 1, stop: second, status: .placed, normalizedCoordinate: second.coordinate,
          snapDistanceMeters: 0),
      ],
      legs: [
        MaritimeRouteLeg(
          id: "leg",
          startIndex: 0,
          endIndex: 1,
          startStopID: first.id,
          endStopID: second.id,
          coordinates: [
            first.coordinate,
            MaritimeCoordinate(latitude: 54, longitude: 8.01),
            second.coordinate,
          ]
        )
      ],
      diagnostics: []
    )
    let presentation = MaritimeMapPresentation(result: result)
    #expect(result.routeArrows.count == 1)
    #expect(result.routePolylines.count == 1)
    #expect(MaritimeMapViewport.region(for: presentation.allCoordinates) != nil)
  }

  @Test("Distances use wrapped geodesics and sum successful legs")
  func distances() {
    let first = MaritimeRouteLeg(
      id: "first", startIndex: 0, endIndex: 1, startStopID: "a", endStopID: "b",
      coordinates: [
        MaritimeCoordinate(latitude: 0, longitude: 0),
        MaritimeCoordinate(latitude: 0, longitude: 1),
      ])
    let dateline = MaritimeRouteLeg(
      id: "dateline", startIndex: 2, endIndex: 3, startStopID: "c", endStopID: "d",
      coordinates: [
        MaritimeCoordinate(latitude: 0, longitude: 179),
        MaritimeCoordinate(latitude: 0, longitude: -179),
      ])
    let trivial = MaritimeRouteLeg(
      id: "trivial", startIndex: 4, endIndex: 5, startStopID: "e", endStopID: "f",
      coordinates: [MaritimeCoordinate(latitude: 0, longitude: 0)])
    let result = MaritimeRouteResult(
      placements: [], legs: [first, dateline, trivial],
      diagnostics: [
        MaritimeRouteDiagnostic(
          id: "missing", kind: .legCannotBeRouted, legStartIndex: 1,
          message: "A failed leg is not included in the distance.")
      ])

    #expect(abs(first.distanceInMeters - 111_195) < 10)
    #expect(abs(dateline.distanceInMeters - 222_390) < 20)
    #expect(trivial.distanceInMeters == 0)
    #expect(abs(first.distanceInNauticalMiles - first.distanceInMeters / 1_852) < 0.000_001)
    #expect(
      abs(result.distanceInMeters - (first.distanceInMeters + dateline.distanceInMeters)) < 0.001)
    #expect(
      abs(result.distanceInNauticalMiles - result.distanceInMeters / 1_852) < 0.000_001)
  }

  @Test("Public presentation geometry is drawable, ordered, and antimeridian safe")
  func resultPresentationGeometry() throws {
    let eastbound = MaritimeRouteLeg(
      id: "eastbound", startIndex: 0, endIndex: 1, startStopID: "a", endStopID: "b",
      coordinates: [
        MaritimeCoordinate(latitude: 10, longitude: 179),
        MaritimeCoordinate(latitude: 10, longitude: -179),
      ])
    let trivial = MaritimeRouteLeg(
      id: "trivial", startIndex: 1, endIndex: 2, startStopID: "b", endStopID: "c",
      coordinates: [MaritimeCoordinate(latitude: 10, longitude: -179)])
    let northbound = MaritimeRouteLeg(
      id: "northbound", startIndex: 2, endIndex: 3, startStopID: "c", endStopID: "d",
      coordinates: [
        MaritimeCoordinate(latitude: 10, longitude: -10),
        MaritimeCoordinate(latitude: 11, longitude: -10),
      ])
    let result = MaritimeRouteResult(
      placements: [], legs: [eastbound, trivial, northbound], diagnostics: [])

    #expect(result.routePolylines.count == 3)
    #expect(result.routePolylines[0].first?.longitude == 179)
    #expect(result.routePolylines[1].last?.longitude == -179)
    #expect(result.routePolylines[2] == northbound.coordinates)
    #expect(result.routePolylines.allSatisfy { $0.count > 1 })
    #expect(
      result.routePolylines.allSatisfy { polyline in
        zip(polyline, polyline.dropFirst()).allSatisfy {
          abs($0.longitude - $1.longitude) <= 180
        }
      })

    #expect(result.routeArrows.map(\.id) == ["eastbound", "northbound"])
    let eastArrow = try #require(result.routeArrows.first)
    #expect(abs(abs(eastArrow.coordinate.longitude) - 180) < 0.001)
    #expect(eastArrow.rotationRadians.isFinite)

    let tooShort = MaritimeRouteResult(
      placements: [],
      legs: [
        MaritimeRouteLeg(
          id: "short", startIndex: 0, endIndex: 1, startStopID: "a", endStopID: "b",
          coordinates: [
            MaritimeCoordinate(latitude: 0, longitude: 0),
            MaritimeCoordinate(latitude: 0, longitude: 0.000_01),
          ])
      ], diagnostics: [])
    #expect(tooShort.routeArrows.isEmpty)
  }

  @Test("Viewport fitting rejects unusable input and pads valid points")
  func viewportValidation() throws {
    #expect(MaritimeMapViewport.region(for: []) == nil)
    #expect(
      MaritimeMapViewport.region(for: [
        MaritimeCoordinate(latitude: .nan, longitude: 0)
      ]) == nil)
    #expect(
      MaritimeMapViewport.region(for: [
        MaritimeCoordinate(latitude: 0, longitude: 181)
      ]) == nil)

    let point = try #require(
      MaritimeMapViewport.region(for: [
        MaritimeCoordinate(latitude: 53.5, longitude: 9.9)
      ]))
    #expect(point.center.latitude == 53.5)
    #expect(abs(point.center.longitude - 9.9) < 0.000_001)
    #expect(point.span.latitudeDelta == 0.08)
    #expect(point.span.longitudeDelta == 0.08)
  }
}

private func stop(_ id: String, _ title: String, _ latitude: Double, _ longitude: Double)
  -> MaritimeRouteStop
{
  MaritimeRouteStop(
    id: id,
    title: title,
    coordinate: MaritimeCoordinate(latitude: latitude, longitude: longitude)
  )
}
