# Getting Started

Plan an ordered itinerary offline and present its route in SwiftUI.

## Create an Itinerary

Create one ``MaritimeRouteStop`` for each itinerary call. Repeated visits need
different IDs because IDs identify calls, not port records.

```swift
let stops = [
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
```

For the package's fixed presentation, pass the stops directly to
``MaritimeRouteMap``:

```swift
MaritimeRouteMap(stops: stops)
```

## Plan and Inspect a Route

Reuse one ``MaritimeRoutePlanner`` actor so its loaded data and route cache can
serve later plans.

```swift
let planner = MaritimeRoutePlanner()
let result = await planner.plan(stops: stops)

print("Distance: \(result.distanceInNauticalMiles) nm")

for placement in result.placements {
    print(placement.stop.title, placement.status)
}

for diagnostic in result.diagnostics {
    print(diagnostic.message)
}
```

The method returns diagnostics instead of throwing for invalid coordinates,
unplaceable stops, unroutable legs, or unavailable bundled data. Distances only
sum successful legs, so inspect `diagnostics` before treating the result as a
complete itinerary.

## Draw in a SwiftUI Map

``MaritimeRouteResult/routePolylines`` already splits routes at the
antimeridian. ``MaritimeRouteResult/routeArrows`` supplies screen-oriented
midpoint markers.

```swift
Map {
    ForEach(Array(result.routePolylines.enumerated()), id: \.offset) { _, part in
        MapPolyline(coordinates: part.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        })
        .stroke(.blue, lineWidth: 2)
    }

    ForEach(result.routeArrows) { arrow in
        Annotation("", coordinate: CLLocationCoordinate2D(
            latitude: arrow.coordinate.latitude,
            longitude: arrow.coordinate.longitude
        )) {
            Image(systemName: "arrow.right")
                .rotationEffect(.radians(arrow.rotationRadians))
        }
    }
}
```

Use ``MaritimeMapViewport/region(for:)`` to fit the same coordinates without
implementing circular-longitude bounds yourself.
