# ``MaritimeRouteResult``

## Overview

The result of a maritime route calculation.

A ``MaritimeRouteResult`` contains the computed route path, represented as a series of ``MaritimeRouteLeg`` objects, as well as the total distance, estimated travel time, and any generated ``MaritimeRouteDiagnostic`` messages.

> Important: Always check the ``diagnostics`` property to ensure the route is safe for the intended vessel.

## Topics

### Properties
- ``legs``
- ``totalDistance``
- ``estimatedDuration``
- ``diagnostics``
