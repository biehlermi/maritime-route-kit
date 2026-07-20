# ``MaritimeRouteKit``

Plan deterministic, offline, illustrative water routes for ordered itineraries.

## Overview

MaritimeRouteKit places itinerary calls on a bundled navigable-water graph,
plans each consecutive leg, and reports successful geometry alongside
structured diagnostics. Use the fixed ``MaritimeRouteMap`` or render a
``MaritimeRouteResult`` in your own MapKit or SwiftUI interface.

> Important: MaritimeRouteKit is not a navigation system and does not model the
> conditions, rules, charts, or vessel characteristics needed for safe passage.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:PlannerAPI>
- <doc:KnownLimitations>

### Planning and Results

- ``MaritimeRoutePlanner``
- ``MaritimeRouteStop``
- ``MaritimeRouteResult``
- ``MaritimeRouteLeg``
- ``MaritimeStopPlacement``
- ``MaritimeRouteDiagnostic``

### Map Presentation

- ``MaritimeRouteMap``
- ``MaritimeMapViewport``
- ``MaritimeRouteArrow``

### Routing Data and Behavior

- <doc:HowRoutingWorks>
- <doc:CanalsAndConnectors>
- <doc:DataProvenance>

### Integration Reference

- <doc:AIAgentGuide>
