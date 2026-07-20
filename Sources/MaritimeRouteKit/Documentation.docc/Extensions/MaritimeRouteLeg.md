# ``MaritimeRouteLeg``

## Overview

Successful route geometry between two consecutive itinerary calls. Input
indices and stop IDs retain the association even when another leg is omitted.

## Topics

### Creating a Leg

- ``init(id:startIndex:endIndex:startStopID:endStopID:coordinates:)``

### Identity and Itinerary Position

- ``id``
- ``startIndex``
- ``endIndex``
- ``startStopID``
- ``endStopID``

### Geometry and Distance

- ``coordinates``
- ``isTrivial``
- ``distanceInMeters``
- ``distanceInNauticalMiles``
