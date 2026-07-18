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
    #expect(result.placements[1].status == .noNavigableWaterWithin25Kilometers)
    #expect(result.diagnostics.contains { $0.kind == .invalidCoordinate })
    #expect(result.diagnostics.contains { $0.kind == .stopCannotBePlaced })
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

@Suite("Map presentation")
struct MapPresentationTests {
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
    let region = MapViewport.region(for: coordinates)
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
    #expect(presentation.arrows.count == 1)
    #expect(presentation.routeParts.count == 1)
    #expect(MapViewport.region(for: presentation.allCoordinates) != nil)
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
