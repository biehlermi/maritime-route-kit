# MaritimeRouteKit

MaritimeRouteKit is an iOS 27 Swift package that draws an ordered cruise
itinerary on a fixed-style MapKit map. Route calculation is local,
deterministic, and does not use an online routing service.

> **Not for navigation.** Routes are illustrative geometry. They do not account
> for shipping lanes, charted depth, tides, currents, weather, traffic
> separation schemes, lock state or operating schedules, canal restrictions,
> military/restricted waters, port rules, temporary closures, or vessel
> dimensions and handling characteristics.

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

The package contains seven live SwiftUI previews in
`MaritimeRouteMap+Previews.swift`, including Suez and Panama Canal passages and
a 14-stop Caribbean itinerary. Open that file in Xcode and select
**Editor → Canvas** to view them.

## Planner API

Use `MaritimeRoutePlanner` when you need route geometry, placement information,
or diagnostics without the bundled map view. Keep and reuse the actor: it loads
the bundled grids lazily on the first call and caches them for later plans.

```swift
let planner = MaritimeRoutePlanner()
let result = await planner.plan(stops: stops)

for placement in result.placements {
    switch placement.status {
    case .placed:
        print(
            placement.inputIndex,
            placement.normalizedCoordinate as Any,
            placement.snapDistanceMeters as Any
        )
    case .invalidCoordinate, .noNavigableWaterWithin25Kilometers:
        print("Unplaced stop:", placement.stop.title, placement.status)
    }
}

for leg in result.legs {
    // Coordinates run from stops[leg.startIndex] to stops[leg.endIndex].
    drawPolyline(leg.coordinates)
}
```

`plan(stops:)` is asynchronous and returns a result instead of throwing. Its
three arrays have stable, complementary roles:

| Result member | Contract |
| --- | --- |
| `placements` | Exactly one entry per input stop, in input order. A placed coordinate may differ from the input coordinate because stops can snap to represented water within 25 km. |
| `legs` | Geometry for each successfully planned pair of consecutive stops. Use `startIndex` and `endIndex`; do not assume `legs[index]` exists when an earlier leg failed. Repeated or colocated calls produce a trivial one-coordinate leg. |
| `diagnostics` | Structured stop, leg, or bundled-data failures. `stopIndex` and `legStartIndex` associate a diagnostic with the original itinerary. |

Invalid or unplaceable stops and unsuccessful legs are reported explicitly.
The planner never substitutes a straight line across represented land, and a
failure on one leg does not prevent later independent legs from being planned.
Planning is offline, deterministic for the same package data and input order,
and safe to call from a SwiftUI task.

### Canals and other connectors

Suez and Panama are bundled as high-resolution, two-portal connector grids.
The planner can select them automatically for an advantageous passage, so an
explicit “Suez Canal” or “Panama Canal” stop is not required. A stop inside a
connector is also supported, which is useful when displaying the passage as an
itinerary call.

Connector handling is data-driven. Runtime code discovers every `.mrkgrid`
resource and derives transitions from its gateways; there is no Swift list of
canal names or canal coordinates. To add another canal, strait, river reach, or
similar region, add its bounds, open-water gateways, and source-selection rules
to `Tools/waterways.json`, commit the corresponding Overpass query, and rebuild
the grid. No planner source change is required.

## How routing works

- A bit-packed Natural Earth 1:10m ocean grid supplies global illustrative
  coverage and a conservative 2 km open-water land clearance.
- OpenStreetMap-derived patches add a conservative sub-100 m geometric
  clearance in constrained waterways where 2 km is physically impossible:
  the tidal Elbe, Bergen approach, Geirangerfjord, Stockholm archipelago, Suez
  Canal, and Panama Canal.
- Stops over land snap to the closest represented navigable water point within
  25 km.
- A bidirectional global grid search uses geodesic distance and a turn penalty.
  Multi-gateway connector transitions and single-gateway constrained approaches
  use precomputed deterministic water-only trees. Safe line-of-sight
  simplification, interpolation, and raster-corner repair remove grid-like steps
  while revalidating the returned geometry.
- Polylines are split at the antimeridian before MapKit renders them.

Route selection prefers lower-cost water-safe geometry represented by these
grids, but does not claim a globally shortest passage. It does **not** mean the
route that a master, pilot, or voyage-planning system would choose.

## Data provenance and licenses

The global ocean mask is derived from Natural Earth 1:10m ocean version 5.1.1,
which is public domain. The high-detail patch database is derived from
OpenStreetMap data and remains available under ODbL 1.0. Exact extraction
dates, queries, checksums, attribution, and rebuild instructions are in
[`DataSources/SOURCES.md`](DataSources/SOURCES.md).

The Swift source is MIT-licensed. The ODbL-covered derived grids are separate
data resources and are not relicensed under MIT.

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

The data preprocessor uses only Python’s standard library:

```sh
python3 Tools/build_water_data.py --help
```

Run the iOS package tests from Xcode, or with an installed simulator:

```sh
xcodebuild -scheme MaritimeRouteKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
