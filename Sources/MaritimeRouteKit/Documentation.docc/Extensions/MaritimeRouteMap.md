# ``MaritimeRouteMap``

## Overview

A visual representation of maritime routes and navigational data.

``MaritimeRouteMap`` provides an interface for rendering a ``MaritimeRouteResult``, ``MaritimeRouteStop`` points, and other maritime map features on a digital chart.

```swift
let map = MaritimeRouteMap()
map.display(route: myRouteResult)
```

## Topics

### Properties
- ``visibleRegion``
- ``displayedRoutes``

### Methods
- ``display(route:)``
- ``clearRoutes()``
