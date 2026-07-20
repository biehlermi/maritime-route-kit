# ``MaritimeCoordinate``

## Overview

A value-only latitude and longitude pair used by MaritimeRouteKit. The
initializer stores values as supplied; the planner validates finite latitude in
−90°...90° and longitude in −180°...180° before placement.

## Topics

### Creating a Coordinate

- ``init(latitude:longitude:)``

### Coordinate Values

- ``latitude``
- ``longitude``
