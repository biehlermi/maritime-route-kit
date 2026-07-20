# ``MaritimeRoutePlanner``

## Overview

An actor that lazily loads the bundled water graph and plans deterministic,
offline itinerary legs. Reuse an instance to preserve its loaded resource and
bounded route caches.

```swift
let planner = MaritimeRoutePlanner()
let result = await planner.plan(
    stops: stops,
    maximumSnapDistanceMeters: 10_000
)
```

The method returns diagnostics rather than throwing for routing failures.

## Topics

### Creating a Planner

- ``init()``

### Planning

- ``plan(stops:maximumSnapDistanceMeters:)``
