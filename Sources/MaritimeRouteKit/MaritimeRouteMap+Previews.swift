import SwiftUI

#if DEBUG
  private enum PreviewItineraries {
    static let hamburgToBergen = [
      MaritimeRouteStop(
        id: "hamburg-1",
        title: "Hamburg",
        coordinate: MaritimeCoordinate(latitude: 53.535, longitude: 9.950)
      ),
      MaritimeRouteStop(
        id: "bergen-1",
        title: "Bergen",
        coordinate: MaritimeCoordinate(latitude: 60.392, longitude: 5.323)
      ),
    ]

    static let hamburgToGeiranger = [
      MaritimeRouteStop(
        id: "hamburg-1",
        title: "Hamburg",
        coordinate: MaritimeCoordinate(latitude: 53.535, longitude: 9.950)
      ),
      MaritimeRouteStop(
        id: "geiranger-1",
        title: "Geiranger",
        coordinate: MaritimeCoordinate(latitude: 62.1015, longitude: 7.207)
      ),
    ]

    static let baltic = [
      MaritimeRouteStop(
        id: "kiel-1",
        title: "Kiel",
        coordinate: MaritimeCoordinate(latitude: 54.323, longitude: 10.139)
      ),
      MaritimeRouteStop(
        id: "copenhagen-1",
        title: "Copenhagen",
        coordinate: MaritimeCoordinate(latitude: 55.690, longitude: 12.600)
      ),
      MaritimeRouteStop(
        id: "stockholm-1",
        title: "Stockholm",
        coordinate: MaritimeCoordinate(latitude: 59.329, longitude: 18.069)
      ),
      MaritimeRouteStop(
        id: "helsinki-1",
        title: "Helsinki",
        coordinate: MaritimeCoordinate(latitude: 60.170, longitude: 24.940)
      ),
      MaritimeRouteStop(
        id: "tallinn-1",
        title: "Tallinn",
        coordinate: MaritimeCoordinate(latitude: 59.442, longitude: 24.754)
      ),
    ]
  }

  #Preview("Hamburg – Bergen") {
    MaritimeRouteMap(stops: PreviewItineraries.hamburgToBergen)
      .ignoresSafeArea()
  }

  #Preview("Hamburg – Geirangerfjord") {
    MaritimeRouteMap(stops: PreviewItineraries.hamburgToGeiranger)
      .ignoresSafeArea()
  }

  #Preview("Baltic") {
    MaritimeRouteMap(stops: PreviewItineraries.baltic)
      .ignoresSafeArea()
  }
#endif
