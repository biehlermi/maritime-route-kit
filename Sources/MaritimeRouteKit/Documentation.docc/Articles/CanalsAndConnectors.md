# Canals and Connectors

Routing through major artificial waterways and straits.

## Overview

Global maritime routing heavily depends on key chokepoints and canals. MaritimeRouteKit explicitly models these vital links to provide accurate, real-world routes.

## Major Canals Supported

The routing network includes specific high-priority connections for:

- **The Panama Canal**: Connecting the Atlantic and Pacific oceans.
- **The Suez Canal**: Connecting the Mediterranean Sea to the Red Sea.
- **The Kiel Canal**: Connecting the North Sea to the Baltic Sea.

## Automatic Selection

The ``MaritimeRoutePlanner`` evaluates these canals dynamically during the A* search. Based on the start and end points, it automatically determines if passing through a canal yields a shorter overall distance compared to alternative routes (e.g., going around Cape Horn or the Cape of Good Hope).

> Note: The current implementation routes based purely on distance. It does not account for canal tolls, waiting times, or vessel size restrictions (e.g., Panamax limits).
