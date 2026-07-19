#if !DEBUG
  import Foundation
  import Testing

  @testable import MaritimeRouteKit

  @Suite("Release routing performance", .serialized)
  struct ReleasePerformanceTests {
    @Test("iPhone simulator routing gates")
    func routingGates() async throws {
      let clock = ContinuousClock()

      var start = clock.now
      let planner = MaritimeRoutePlanner()
      let initialized = await planner.plan(stops: [benchmarkStop("warm", 0, -150)])
      let initializationMilliseconds = milliseconds(start.duration(to: clock.now))
      #expect(initialized.placements.first?.status == .placed)
      #expect(initializationMilliseconds <= 400)

      var ordinarySamples: [Double] = []
      for index in 0..<20 {
        let latitude = -38.0 + Double(index) * 4
        start = clock.now
        let result = await planner.plan(stops: [
          benchmarkStop("ordinary-start-\(index)", latitude, -160),
          benchmarkStop("ordinary-end-\(index)", latitude, -150),
        ])
        ordinarySamples.append(milliseconds(start.duration(to: clock.now)))
        #expect(result.legs.count == 1)
      }
      #expect(percentile95(ordinarySamples) <= 100)

      start = clock.now
      let suez = await planner.plan(stops: [
        benchmarkStop("barcelona", 41.3851, 2.1734),
        benchmarkStop("dubai", 25.2048, 55.2708),
      ])
      let suezMilliseconds = milliseconds(start.duration(to: clock.now))
      #expect(suez.legs.count == 1)
      #expect(suezMilliseconds <= 300)

      start = clock.now
      let panamaEastbound = await planner.plan(stops: [
        benchmarkStop("puntarenas-eastbound", 9.9763, -84.8384),
        benchmarkStop("cartagena-eastbound", 10.3910, -75.4794),
      ])
      let panamaWestbound = await planner.plan(stops: [
        benchmarkStop("cartagena-westbound", 10.3910, -75.4794),
        benchmarkStop("puntarenas-westbound", 9.9763, -84.8384),
      ])
      let panamaMilliseconds = milliseconds(start.duration(to: clock.now))
      #expect(panamaEastbound.legs.count == 1)
      #expect(panamaWestbound.legs.count == 1)
      #expect(panamaMilliseconds <= 500)

      start = clock.now
      let caribbean = await planner.plan(stops: benchmarkCaribbeanStops)
      let caribbeanMilliseconds = milliseconds(start.duration(to: clock.now))
      #expect(caribbean.legs.count == 13)
      #expect(caribbeanMilliseconds <= 1_000)
    }
  }

  private func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000 + Double(components.attoseconds)
      / 1_000_000_000_000_000
  }

  private func percentile95(_ samples: [Double]) -> Double {
    let sorted = samples.sorted()
    let index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
    return sorted[index]
  }

  private func benchmarkStop(_ id: String, _ latitude: Double, _ longitude: Double)
    -> MaritimeRouteStop
  {
    MaritimeRouteStop(
      id: id,
      title: id,
      coordinate: MaritimeCoordinate(latitude: latitude, longitude: longitude)
    )
  }

  private let benchmarkCaribbeanStops = [
    benchmarkStop("miami", 25.7743, -80.1572),
    benchmarkStop("nassau", 25.0781, -77.3385),
    benchmarkStop("grand-turk", 21.4603, -71.1419),
    benchmarkStop("san-juan", 18.4655, -66.1057),
    benchmarkStop("st-thomas", 18.3405, -64.9307),
    benchmarkStop("st-maarten", 18.0204, -63.0458),
    benchmarkStop("antigua", 17.1212, -61.8440),
    benchmarkStop("guadeloupe", 16.2306, -61.5364),
    benchmarkStop("dominica", 15.2967, -61.3870),
    benchmarkStop("martinique", 14.6008, -61.0690),
    benchmarkStop("st-lucia", 14.0101, -60.9990),
    benchmarkStop("barbados", 13.1000, -59.6167),
    benchmarkStop("grenada", 12.0500, -61.7500),
    benchmarkStop("curacao", 12.1084, -68.9335),
  ]
#endif
