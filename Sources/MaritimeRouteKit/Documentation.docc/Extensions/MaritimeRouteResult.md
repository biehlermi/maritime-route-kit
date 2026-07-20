# ``MaritimeRouteResult``

## Overview

The deterministic output of planning an itinerary. Placements correspond to all
input stops, while legs and distances include successful routes only. Inspect
diagnostics before treating the output as complete.

## Topics

### Creating a Result

- ``init(placements:legs:diagnostics:)``

### Planning Output

- ``placements``
- ``legs``
- ``diagnostics``
- ``isComplete``

### Distances

- ``distanceInMeters``
- ``distanceInNauticalMiles``

### Map Presentation

- ``routePolylines``
- ``routeArrows``
