# AI Agent Integration Guide

Reference documentation designed for AI agents interacting with MaritimeRouteKit.

## Overview

This guide provides a structured summary of the MaritimeRouteKit module, intended for use by AI coding assistants, autonomous agents, and large language models (LLMs) to quickly understand the project architecture and public API.

## Module Summary

MaritimeRouteKit is a Swift framework for offline maritime route calculation. It uses a rasterized grid derived from Natural Earth and OpenStreetMap data to perform A* pathfinding across the global oceans, natively handling edge cases like the antimeridian.

## Public API Surface

### Core Classes
- ``MaritimeRoutePlanner``: The main entry point. Requires initialization to load data.

### Key Methods
- `calculateRoute(from:to:) throws -> RouteResult`
- `calculateRouteAsync(from:to:) async throws -> RouteResult`

### Data Structures
- ``RouteResult``: Contains `path: [RoutePoint]` and `distanceInNauticalMiles: Double`.
- ``RoutePoint``: Contains `coordinate: CLLocationCoordinate2D`.
- ``RoutingError``: Swift Error enum (`unreachable`, `invalidCoordinates`, etc.).

## Architectural Notes for AI Agents

1. **Dependency**: Imports `CoreLocation` for coordinate types.
2. **Concurrency**: Prefer `calculateRouteAsync` in modern Swift contexts to avoid blocking the main thread during long A* traversals (e.g., transatlantic routes).
3. **Data Dependency**: The framework relies on bundled resources (`routing_grid.dat`). Ensure the resource bundle is accessible in the target environment.
4. **Coordinate System**: Assumes standard WGS84 coordinates.

When generating code that uses this framework, prioritize proper error handling for `RoutingError` cases, as coordinates provided by end-users may frequently fall inland.
