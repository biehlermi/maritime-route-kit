# Getting Started

Learn how to integrate MaritimeRouteKit into your Swift applications.

## Overview

MaritimeRouteKit provides an easy-to-use API for calculating maritime routes. The core of the framework is the ``MaritimeRoutePlanner`` class, which handles the complex routing logic using offline data.

## Basic Usage

To calculate a route, create an instance of ``MaritimeRoutePlanner`` and call its routing method with starting and ending coordinates.

```swift
import MaritimeRouteKit
import CoreLocation

let planner = MaritimeRoutePlanner()
let start = CLLocationCoordinate2D(latitude: 34.05, longitude: -118.24) // Los Angeles
let end = CLLocationCoordinate2D(latitude: 35.68, longitude: 139.69) // Tokyo

do {
    let result = try planner.calculateRoute(from: start, to: end)
    print("Route distance: \(result.distanceInNauticalMiles) nm")
    for point in result.path {
        print("Point: \(point.coordinate.latitude), \(point.coordinate.longitude)")
    }
} catch {
    print("Routing failed: \(error)")
}
```

## Using with SwiftUI

You can easily integrate route calculation into your SwiftUI views using the async API.

```swift
import SwiftUI
import MapKit
import MaritimeRouteKit

struct RouteMapView: View {
    @State private var planner = MaritimeRoutePlanner()
    @State private var route: RouteResult?
    
    var body: some View {
        Map {
            if let route = route {
                MapPolyline(coordinates: route.path.map(\.coordinate))
                    .stroke(.blue, lineWidth: 2)
            }
        }
        .task {
            // Calculate route on appear
            let start = CLLocationCoordinate2D(latitude: 40.71, longitude: -74.00) // NY
            let end = CLLocationCoordinate2D(latitude: 51.50, longitude: -0.12) // London
            
            do {
                route = try await planner.calculateRouteAsync(from: start, to: end)
            } catch {
                print("Error: \(error)")
            }
        }
    }
}
```
