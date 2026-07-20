# MaritimeRouteKit

MaritimeRouteKit is an iOS 26 Swift package that draws an ordered cruise
itinerary on a fixed-style MapKit map. Route calculation is local,
deterministic, and does not use an online routing service.

> **Not for navigation.** Routes are illustrative geometry. They do not account
> for shipping lanes, charted depth, tides, currents, weather, traffic
> separation schemes, lock state or operating schedules, canal restrictions,
> military/restricted waters, port rules, temporary closures, or vessel
> dimensions and handling characteristics.

## Requirements

- iOS 26 or newer
- Xcode 26.3 or newer
- Swift 6.3 or newer

## Add the package

In Xcode, choose **File → Add Package Dependencies…** and select this repository.
For a local checkout, choose **Add Local…** and select the repository folder.

Then import the library and provide ordered itinerary calls:

```swift
import MaritimeRouteKit
import SwiftUI

struct ItineraryView: View {
    private let stops = [
        MaritimeRouteStop(
            id: "hamburg-2027-06-03",
            title: "Hamburg",
            coordinate: MaritimeCoordinate(latitude: 53.535, longitude: 9.950)
        ),
        MaritimeRouteStop(
            id: "geiranger-2027-06-07",
            title: "Geiranger",
            coordinate: MaritimeCoordinate(latitude: 62.1015, longitude: 7.207)
        ),
    ]

    var body: some View {
        MaritimeRouteMap(stops: stops)
    }
}
```

The package contains seven live SwiftUI previews in
`MaritimeRouteMap+Previews.swift`, including Suez and Panama Canal passages and
a 14-stop Caribbean itinerary. Open that file in Xcode and select
**Editor → Canvas** to view them.

## Planner API

Use `MaritimeRoutePlanner` when you need route geometry, placement information,
or diagnostics without the bundled map view. Keep and reuse the actor: it loads
the single bundled worldwide resource lazily on the first call and reuses its
tile, graph-search, and route caches for later plans.

```swift
let planner = MaritimeRoutePlanner()
let result = await planner.plan(stops: stops)

print(result.distanceInMeters)
print(result.distanceInNauticalMiles)

for placement in result.placements {
    switch placement.status {
    case .placed:
        print(
            placement.inputIndex,
            placement.normalizedCoordinate as Any,
            placement.snapDistanceMeters as Any
        )
    case .invalidCoordinate, .noNavigableWater, .routingDataUnavailable:
        print("Unplaced stop:", placement.stop.title, placement.status)
    }
}

for leg in result.legs {
    // Coordinates run from stops[leg.startIndex] to stops[leg.endIndex].
    drawPolyline(leg.coordinates)
}
```

To use a stricter placement policy for one request, pass a value from zero
through the default 25 km ceiling:

```swift
let result = await planner.plan(
    stops: stops,
    maximumSnapDistanceMeters: 5_000
)
```

`plan(stops:)` is asynchronous and returns a result instead of throwing. Its
three arrays have stable, complementary roles:

| Result member | Contract |
| --- | --- |
| `placements` | Exactly one entry per input stop, in input order. A placed coordinate may differ from the input coordinate because stops can snap to represented water within the configured limit (25 km by default). |
| `legs` | Geometry for each successfully planned pair of consecutive stops. Use `startIndex` and `endIndex`; do not assume `legs[index]` exists when an earlier leg failed. Repeated or colocated calls produce a trivial one-coordinate leg. |
| `diagnostics` | Structured stop, leg, or bundled-data failures. `stopIndex` and `legStartIndex` associate a diagnostic with the original itinerary. |

Invalid or unplaceable stops and unsuccessful legs are reported explicitly.
The planner never substitutes a straight line across represented land, and a
failure on one leg does not prevent later independent legs from being planned.
Planning is offline, deterministic for the same package data and input order,
and safe to call from a SwiftUI task.

`result.isComplete` is convenient shorthand for `result.diagnostics.isEmpty`.
It means planning reported no failures; it does not make the illustrative route
safe or suitable for navigation.

`distanceInMeters` and `distanceInNauticalMiles` are available on each leg and
on the result. Result distances sum successful legs only, so check diagnostics
before treating them as the distance of the complete requested itinerary.

### Custom MapKit and SwiftUI presentation

`result.routePolylines` returns drawable coordinate arrays that are already
split at the antimeridian, and `result.routeArrows` returns one screen-oriented
midpoint arrow for every leg longer than ten meters. This lets a SwiftUI `Map`
consumer avoid duplicating the package's dateline and direction calculations.

Use `MaritimeMapViewport.region(for:)` to calculate the same padded,
antimeridian-aware `MKCoordinateRegion` used by the bundled map view.

### Canals and other connectors

Suez and Panama currently have bundled high-resolution masks and internal
passage annotations. The planner selects them automatically when advantageous;
callers do not name a canal, select a data product, or configure availability.
A stop inside a represented connector is supported as well.

All global and detailed regions feed one graph, so a route can compose any
number of represented canals, straits, coastal approaches, and fjords. Adding a
region changes the build-time manifest and regenerated `world.mrkroute`, not the
Swift routing logic or public API.

## How routing works

- A compressed Natural Earth 1:10m ocean mask supplies worldwide illustrative
  open-water coverage at 0.025°. OpenStreetMap-derived detail currently covers
  the tidal Elbe, Bergen approach, Geirangerfjord, Stockholm archipelago, Suez
  Canal, and Panama Canal at sub-100 m cell sizes.
- Stops over land snap to the closest represented navigable water point within
  the per-plan limit, which defaults to 25 km.
- A hierarchical portal graph connects the tiled masks. Bounded local searches
  attach each endpoint to up to four graph nodes; flat-array A* then finds the
  worldwide path with geodesic distance as its heuristic. Contextual graph
  edges are reconstructed inside their source tile.
- Water masks are stored as independently raw-DEFLATE-compressed 128×128 tiles;
  all-land and all-water tiles have no payload. Runtime decoding is bounded by a
  32 MiB LRU cache, and graph and route-search scratch storage is reused.
- Water-validated line-of-sight simplification removes grid-like steps. Every
  returned segment is checked against the finest available mask; an unsuccessful
  search never falls back to an unchecked straight line.
- Polylines are split at the antimeridian before MapKit renders them.

Route selection prefers lower-cost water-safe geometry represented by the
bundled dataset, but does not claim a navigationally optimal passage. It does
**not** mean the route that a master, pilot, or voyage-planning system would
choose.

## Data provenance and licenses

The global ocean mask is derived from Natural Earth 1:10m ocean version 5.1.1,
which is public domain. High-detail masks are derived from OpenStreetMap data
and remain available under ODbL 1.0. The test fixture catalog is derived from
the NGA World Port Index. Exact extraction dates, checksums, attribution, and
rebuild instructions are in
[`DataSources/SOURCES.md`](DataSources/SOURCES.md).

The Swift source is MIT-licensed. The ODbL-covered derived resources are
separate data and are not relicensed under MIT.

## Known limits

- Outside the bundled high-detail regions, Natural Earth’s scale omits small
  islands, narrow channels, harbor basins, and river approaches.
- Inland lakes are not treated as ocean routes.
- A represented canal is only geometric connectivity. Lock availability,
  booking, convoy rules, draft/beam/air-draft limits, fees, and closures are not
  modeled.
- The fixed clearance policy can reject a real-world passage or accept water
  that is unsuitable for a particular ship.
- MapKit tiles follow normal system availability even though route planning is
  offline.
- Port labels are always requested at required display priority, but labels can
  visually overlap in dense itineraries.

## Rebuilding and testing

The data preprocessors use only Python’s standard library. First create the
unshipped intermediate masks, then compile them into the only runtime resource:

```sh
python3 Tools/build_water_data.py \
  --natural-earth-shp path/to/ne_10m_ocean.shp \
  --source elbe=path/to/elbe-water.json \
  --source bergen=path/to/bergen-coastline.json \
  --source geirangerfjord=path/to/geiranger-coastline.json \
  --source stockholm=path/to/stockholm-coastline.json \
  --source suez=path/to/suez-water.json \
  --source panama=path/to/panama-water.json \
  --output path/to/intermediate-grids

python3 Tools/build_world_route.py \
  --grid-directory path/to/intermediate-grids \
  --output Sources/MaritimeRouteKit/Resources/world.mrkroute

python3 Tools/inspect_world_route.py \
  Sources/MaritimeRouteKit/Resources/world.mrkroute
```

The committed resource is about 5.3 MiB; generation and CI reject it if it
exceeds 25 MiB. Identical pinned inputs produce byte-identical output.

Run the iOS package tests from Xcode, or with an installed simulator:

```sh
xcodebuild -scheme MaritimeRouteKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Release-only performance gates use the same suite with optimized code:

```sh
xcodebuild -scheme MaritimeRouteKit \
  -configuration Release \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  ENABLE_TESTABILITY=YES test
```
