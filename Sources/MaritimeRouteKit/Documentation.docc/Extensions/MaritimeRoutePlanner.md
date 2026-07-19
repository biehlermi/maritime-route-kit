# ``MaritimeRoutePlanner``

## Overview

The primary interface for calculating maritime routes.

Use ``MaritimeRoutePlanner`` to generate a ``MaritimeRouteResult`` between multiple ``MaritimeRouteStop`` locations, taking into account navigational constraints, depth, and weather conditions.

```swift
let planner = MaritimeRoutePlanner(configuration: .default)
let result = try await planner.calculateRoute(from: start, to: destination)
```

## Topics

### Initialization
- ``init(configuration:)``

### Methods
- ``calculateRoute(from:to:)``
- ``calculateRoute(stops:)``
