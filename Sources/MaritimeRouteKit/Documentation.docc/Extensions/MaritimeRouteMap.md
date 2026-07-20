# ``MaritimeRouteMap``

## Overview

A fixed-style SwiftUI view backed by MapKit. It displays valid stops
immediately, plans offline, then replaces them with normalized placements and
draws successful antimeridian-safe legs with midpoint arrows.

```swift
MaritimeRouteMap(stops: itineraryStops)
    .ignoresSafeArea()
```

## Topics

### Creating a Map

- ``init(stops:)``
