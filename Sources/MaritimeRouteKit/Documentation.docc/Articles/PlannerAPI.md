# Planner API Reference

Using MaritimeRoutePlanner directly and interpreting its results.

## Overview

The ``MaritimeRoutePlanner`` is the primary entry point for all route calculations in MaritimeRouteKit. It provides synchronous and asynchronous methods for finding paths across the global maritime network.

## Initializing the Planner

Creating a planner instance loads the necessary offline routing data into memory. This operation is generally fast, but for performance-critical applications, consider reusing a single instance.

```swift
let planner = MaritimeRoutePlanner()
```

## Calculating Routes

Use the calculation methods to find a route between two coordinates. The planner will automatically find the nearest navigable water point if the provided coordinates are slightly inland.

### Synchronous Routing

For simple scripts or background queues:

```swift
let result = try planner.calculateRoute(from: origin, to: destination)
```

### Asynchronous Routing

For modern Swift concurrency applications:

```swift
let result = try await planner.calculateRouteAsync(from: origin, to: destination)
```

## Interpreting Results

A successful calculation returns a ``RouteResult`` object, which contains:

- `path`: An array of ``RoutePoint`` objects defining the continuous path.
- `distanceInNauticalMiles`: The total computed distance along the route.
- `estimatedTime`: If a speed profile was provided (optional feature).

## Handling Errors

If a route cannot be found, the planner throws a ``RoutingError``. Common errors include:

- `unreachable`: The destination is isolated (e.g., an inland lake without sea access).
- `invalidCoordinates`: Coordinates are outside valid bounds (-90 to 90 latitude).
- `noData`: The routing grid data is missing or corrupted.
