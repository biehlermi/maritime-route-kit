import MapKit
import Testing

import MaritimeRouteKit

@Suite("Public consumer API")
struct PublicAPITests {
  @Test("Map presentation and distance conveniences are publicly accessible")
  func publicRouteUtilities() throws {
    let leg = MaritimeRouteLeg(
      id: "public-leg",
      startIndex: 0,
      endIndex: 1,
      startStopID: "a",
      endStopID: "b",
      coordinates: [
        MaritimeCoordinate(latitude: 0, longitude: 179),
        MaritimeCoordinate(latitude: 0, longitude: -179),
      ])
    let result = MaritimeRouteResult(placements: [], legs: [leg], diagnostics: [])

    #expect(result.isComplete)
    #expect(result.routePolylines.count == 2)
    #expect(result.routeArrows.first?.id == leg.id)
    #expect(result.distanceInMeters == leg.distanceInMeters)
    #expect(result.distanceInNauticalMiles == leg.distanceInNauticalMiles)
    _ = try #require(MaritimeMapViewport.region(for: leg.coordinates))
  }

  @Test("The public arrow value can be used directly by SwiftUI consumers")
  func publicArrowValue() {
    let arrow = MaritimeRouteArrow(
      id: "leg", coordinate: MaritimeCoordinate(latitude: 1, longitude: 2),
      rotationRadians: .pi / 2)
    #expect(arrow.id == "leg")
    #expect(arrow.rotationRadians == .pi / 2)
  }
}
