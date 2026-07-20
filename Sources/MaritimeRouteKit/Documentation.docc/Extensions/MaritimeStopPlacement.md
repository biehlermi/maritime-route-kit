# ``MaritimeStopPlacement``

## Overview

The outcome of placing one input stop on the represented navigable-water graph.
A successful normalized coordinate can differ from the requested coordinate by
up to the plan's maximum snap distance.

## Topics

### Creating a Placement

- ``init(inputIndex:stop:status:normalizedCoordinate:snapDistanceMeters:)``

### Placement Values

- ``id``
- ``inputIndex``
- ``stop``
- ``status``
- ``normalizedCoordinate``
- ``snapDistanceMeters``
