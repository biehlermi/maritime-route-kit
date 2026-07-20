# Planner API

Use the planner directly when an app needs geometry, placement information, or
diagnostics without the fixed map presentation.

## Planning

``MaritimeRoutePlanner`` is an actor. It loads `world.mrkroute` lazily on the
first plan and retains bounded data and route caches.

```swift
let planner = MaritimeRoutePlanner()
let result = await planner.plan(stops: stops)
```

Planning is asynchronous, deterministic for the same package data and input,
and performs no network requests. Individual itinerary legs may be routed
concurrently.

To enforce a stricter placement policy for one plan, pass a distance from zero
through 25,000 meters:

```swift
let result = await planner.plan(
    stops: stops,
    maximumSnapDistanceMeters: 5_000
)
```

Zero allows coordinates already on represented navigable water and disables
off-water snapping. Values outside the supported range are programmer errors.

## Results

``MaritimeRouteResult`` has three ordered collections:

- `placements` contains exactly one entry for each input stop.
- `legs` contains successful consecutive-stop routes. Failed legs are omitted,
  so use `startIndex` and `endIndex` rather than assuming array indices match.
- `diagnostics` explains invalid stops, placement failures, route failures, or
  an unavailable resource.

A result's `isComplete` property is exactly equivalent to
`diagnostics.isEmpty`. It reports planning completeness, not navigational
safety.

A one-coordinate leg represents colocated calls and has zero distance.
`distanceInMeters` and `distanceInNauticalMiles` sum successful geometry only.

## Presentation Geometry

Use `routePolylines` for antimeridian-safe map overlays and `routeArrows` for one
midpoint direction marker per leg longer than ten meters. Use
``MaritimeMapViewport/region(for:)`` to calculate a padded MapKit region with
correct dateline handling.

> Important: Routes are illustrative geometry, not navigational advice. They do
> not model depth, vessel dimensions, lanes, traffic rules, weather, tides,
> restrictions, locks, or closures.
