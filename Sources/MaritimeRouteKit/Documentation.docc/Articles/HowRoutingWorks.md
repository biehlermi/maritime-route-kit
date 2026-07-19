# How Routing Works

A deep dive into the architecture and algorithms powering MaritimeRouteKit.

## Overview

MaritimeRouteKit operates entirely offline, using a pre-processed grid representing the world's oceans. This grid allows for rapid route calculation without relying on external web services.

## The A* Search Algorithm

The core routing engine employs the A* (A-Star) search algorithm. This algorithm efficiently finds the shortest path by combining:
- The known distance from the start node (g-score).
- A heuristic estimating the distance to the target (h-score), typically based on the great-circle distance.

## Natural Earth Data Masks

To distinguish between land and water, the kit utilizes datasets derived from Natural Earth. During the build process, these high-resolution vector files are rasterized into a discrete grid. This grid acts as a mask, dictating which nodes in the A* graph are navigable.

## Handling the Antimeridian

One of the most complex challenges in global routing is the antimeridian (the 180th meridian). Standard Cartesian grids break at this boundary. MaritimeRouteKit handles this by creating a toroidal graph structure where nodes on the eastern edge logically connect to nodes on the western edge, allowing routes (like crossing the Pacific) to seamlessly split across the dateline in coordinate space.
