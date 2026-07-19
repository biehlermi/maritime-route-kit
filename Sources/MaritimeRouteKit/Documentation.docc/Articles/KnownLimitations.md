# Known Limitations

Understanding the constraints and edge cases of the routing engine.

## Overview

While MaritimeRouteKit provides robust global routing, its offline, grid-based approach introduces certain limitations that developers should be aware of.

## Scale Gaps and Resolution

The routing grid operates at a fixed resolution to balance memory usage and performance. As a result:
- Very narrow channels or straits might be marked as non-navigable if they fall between grid points.
- Coastlines are approximated, meaning a route might visually clip a sharp peninsula when rendered on a high-definition map.

## Inland Waterways and Lakes

The current dataset is optimized for open-ocean and major sea routes.
- **No Inland Lakes**: Routing is not supported within enclosed bodies of water like the Great Lakes or the Caspian Sea, as they do not connect to the global ocean network.
- **Rivers**: River navigation is generally unsupported unless the river mouth is exceptionally wide and captured by the ocean grid mask.

## Dynamic Conditions

The routing engine calculates static distances. It does not factor in:
- Weather conditions, storms, or wave heights.
- Ocean currents.
- Seasonal ice coverage (routes may pass through the Arctic even in winter).
- Piracy risk zones.
