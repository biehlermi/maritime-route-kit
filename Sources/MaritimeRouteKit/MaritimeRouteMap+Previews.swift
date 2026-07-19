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

    static let hamburgToCapeTown = [
      MaritimeRouteStop(
        id: "hamburg-1",
        title: "Hamburg",
        coordinate: MaritimeCoordinate(latitude: 53.535, longitude: 9.950)
      ),
      MaritimeRouteStop(
        id: "gran-canaria-1",
        title: "Gran Canaria",
        coordinate: MaritimeCoordinate(latitude: 28.1248, longitude: -15.4300)
      ),
      MaritimeRouteStop(
        id: "praia-1",
        title: "Praia",
        coordinate: MaritimeCoordinate(latitude: 14.9177, longitude: -23.5092)
      ),
      MaritimeRouteStop(
        id: "cape-town-1",
        title: "Cape Town",
        coordinate: MaritimeCoordinate(latitude: -33.9249, longitude: 18.4241)
      ),
    ]

    static let mallorcaToDubai = [
      MaritimeRouteStop(
        id: "mallorca-1",
        title: "Mallorca",
        coordinate: MaritimeCoordinate(latitude: 39.5696, longitude: 2.6502)
      ),
      MaritimeRouteStop(
        id: "barcelona-1",
        title: "Barcelona",
        coordinate: MaritimeCoordinate(latitude: 41.3851, longitude: 2.1734)
      ),
      /*
      MaritimeRouteStop(
        id: "suez-canal-1",
        title: "Suez Canal",
        coordinate: MaritimeCoordinate(latitude: 30.5852, longitude: 32.2654)
      ),
      */
      MaritimeRouteStop(
        id: "dubai-1",
        title: "Dubai",
        coordinate: MaritimeCoordinate(latitude: 25.2048, longitude: 55.2708)
      ),
    ]

    static let panamaCanal = [
      MaritimeRouteStop(
        id: "cartagena-1",
        title: "Cartagena",
        coordinate: MaritimeCoordinate(latitude: 10.3910, longitude: -75.4794)
      ),
      MaritimeRouteStop(
        id: "panama-canal-1",
        title: "Panama Canal",
        coordinate: MaritimeCoordinate(latitude: 9.1214, longitude: -79.8035)
      ),
      MaritimeRouteStop(
        id: "puntarenas-1",
        title: "Puntarenas",
        coordinate: MaritimeCoordinate(latitude: 9.9763, longitude: -84.8384)
      ),
    ]

    static let caribbean = [
      ("miami", "Miami", 25.7743, -80.1572),
      ("nassau", "Nassau", 25.0781, -77.3385),
      ("grand-turk", "Grand Turk", 21.4603, -71.1419),
      ("san-juan", "San Juan", 18.4655, -66.1057),
      ("st-thomas", "St. Thomas", 18.3405, -64.9307),
      ("st-maarten", "St. Maarten", 18.0204, -63.0458),
      ("antigua", "Antigua", 17.1212, -61.8440),
      ("guadeloupe", "Guadeloupe", 16.2306, -61.5364),
      ("dominica", "Dominica", 15.2967, -61.3870),
      ("martinique", "Martinique", 14.6008, -61.0690),
      ("st-lucia", "St. Lucia", 14.0101, -60.9990),
      ("barbados", "Barbados", 13.1000, -59.6167),
      ("grenada", "Grenada", 12.0500, -61.7500),
      ("curacao", "Curaçao", 12.1084, -68.9335),
    ].map { id, title, latitude, longitude in
      MaritimeRouteStop(
        id: "\(id)-1",
        title: title,
        coordinate: MaritimeCoordinate(latitude: latitude, longitude: longitude)
      )
    }
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

  #Preview("Hamburg – Gran Canaria – Praia – Cape Town") {
    MaritimeRouteMap(stops: PreviewItineraries.hamburgToCapeTown)
      .ignoresSafeArea()
  }

  #Preview("Mallorca – Barcelona – Suez Canal – Dubai") {
    MaritimeRouteMap(stops: PreviewItineraries.mallorcaToDubai)
      .ignoresSafeArea()
  }

  #Preview("Cartagena – Panama Canal – Puntarenas") {
    MaritimeRouteMap(stops: PreviewItineraries.panamaCanal)
      .ignoresSafeArea()
  }

  #Preview("14-stop Caribbean") {
    MaritimeRouteMap(stops: PreviewItineraries.caribbean)
      .ignoresSafeArea()
  }
#endif
