# AI Agent Integration Guide

Use this summary when generating MaritimeRouteKit integrations.

## Actual Public Workflow

1. Build ordered ``MaritimeRouteStop`` values from ``MaritimeCoordinate``
   values.
2. Reuse a ``MaritimeRoutePlanner`` actor.
3. Call `await planner.plan(stops:)`, optionally with a stricter
   `maximumSnapDistanceMeters` from zero through 25,000.
4. Inspect all ``MaritimeRouteResult/placements`` and
   ``MaritimeRouteResult/diagnostics``.
5. Consume successful ``MaritimeRouteResult/legs``, or use
   ``MaritimeRouteResult/routePolylines`` and
   ``MaritimeRouteResult/routeArrows`` for MapKit presentation.

The planner is asynchronous and nonthrowing. There is no `RouteResult`,
`RoutePoint`, `RoutingError`, synchronous calculation API, speed profile, or
route-style configuration.

## Result Semantics

- A placement can be `placed`, `invalidCoordinate`, `noNavigableWater`, or
  `routingDataUnavailable`.
- Legs identify their source calls with itinerary indices and stop IDs.
- Failed legs are omitted and diagnosed; later independent legs can still
  succeed.
- Result distances sum successful leg geometry and may therefore describe only
  a partial itinerary.
- Trivial colocated legs contain one coordinate and have zero distance.

## Architecture and Safety

Routing uses the bundled `world.mrkroute` resource generated from Natural Earth
and selected OpenStreetMap-derived detailed masks. It performs no online route
lookup. Suez and Panama are represented connectors and are selected
automatically when their graph paths are lower cost.

Never describe output as safe or suitable for navigation. The engine does not
know charted depth, vessel characteristics, traffic schemes, rules, weather,
tides, lock operations, restrictions, schedules, or closures.
