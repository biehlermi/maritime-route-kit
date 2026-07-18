# MaritimeRouteKit

MaritimeRouteKit is an iOS 27 Swift package that draws an ordered cruise
itinerary on a fixed-style MapKit map. Route calculation is local,
deterministic, and does not use an online routing service.

> **Not for navigation.** Routes are illustrative geometry. They do not account
> for shipping lanes, charted depth, tides, currents, weather, traffic
> separation schemes, locks or canals, military/restricted waters, port rules,
> temporary closures, or vessel dimensions and handling characteristics.

## Requirements

- iOS 27 or newer
- Xcode 27 or newer
- Swift 6.4 or newer

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

The package contains three live SwiftUI previews in
`MaritimeRouteMap+Previews.swift`: Hamburg–Bergen, Hamburg–Geirangerfjord, and
a Baltic itinerary. Open that file in Xcode and select **Editor → Canvas** to
view them.

## Planner API

Use `MaritimeRoutePlanner` when you need diagnostics or route geometry without
the bundled map view:

```swift
let result = await MaritimeRoutePlanner().plan(stops: stops)

for placement in result.placements {
    print(placement.status, placement.normalizedCoordinate as Any)
}

for diagnostic in result.diagnostics {
    print(diagnostic.kind, diagnostic.message)
}
```

Every input stop has a placement entry. A successful non-trivial consecutive
leg has route geometry. Invalid/unplaceable stops and unsuccessful legs are
reported explicitly; the renderer never substitutes a straight line across
land.

## How routing works

- A bit-packed Natural Earth 1:10m ocean grid supplies global illustrative
  coverage and a conservative 2 km open-water land clearance.
- Date-pinned OpenStreetMap-derived patches add a conservative sub-100 m geometric
  clearance in constrained waterways where 2 km is physically impossible:
  the tidal Elbe, Bergen approach, Geirangerfjord, and Stockholm archipelago.
- Stops over land snap to the closest represented navigable water point within
  25 km.
- Global A* uses geodesic distance and a turn penalty. Precomputed deterministic
  gateway trees make high-resolution constrained approaches fast. Safe
  line-of-sight simplification and rounding remove grid-like steps.
- Polylines are split at the antimeridian before MapKit renders them.

“Shortest” means the lowest-cost water-safe geometry represented by these
grids. It does **not** mean the route that a master, pilot, or voyage-planning
system would choose.

## Data provenance and licenses

The global ocean mask is derived from Natural Earth 1:10m ocean version 5.1.1,
which is public domain. The high-detail patch database is derived from
OpenStreetMap data dated 2026-07-18 and remains available under ODbL 1.0. Exact
queries, checksums, attribution, and rebuild instructions are in
[`DataSources/SOURCES.md`](DataSources/SOURCES.md).

The Swift source is MIT-licensed. The ODbL-covered derived grids are separate
data resources and are not relicensed under MIT.

## Known limits

- Outside the bundled high-detail regions, Natural Earth’s scale omits small
  islands, narrow channels, harbor basins, and river approaches.
- Inland lakes are not treated as ocean routes.
- The fixed clearance policy can reject a real-world passage or accept water
  that is unsuitable for a particular ship.
- MapKit tiles follow normal system availability even though route planning is
  offline.
- Port labels are always requested at required display priority, but labels can
  visually overlap in dense itineraries.

## Rebuilding and testing

The data preprocessor uses only Python’s standard library:

```sh
python3 Tools/build_water_data.py --help
```

Run the iOS package tests from Xcode, or with an installed simulator:

```sh
xcodebuild -scheme MaritimeRouteKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
