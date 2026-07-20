# How Routing Works

MaritimeRouteKit plans deterministic illustrative routes entirely on device.

## Water Representation

A coarse global Natural Earth mask provides worldwide ocean coverage. Selected
OpenStreetMap-derived grids provide finer representation for constrained
coasts, fjords, archipelagos, and the Suez and Panama connectors. The masks are
conservatively eroded according to their build-time clearance values.

## Placement and Search

Each valid stop is placed on the finest available navigable grid within the
plan's maximum snap distance. Bounded local searches attach placed endpoints to
a precomputed portal graph. A* selects graph edges using geodesic costs, while
local detailed searches include a fixed shore-proximity penalty.

Selected graph sections are reconstructed through their source tiles. A
line-of-sight simplifier removes unnecessary grid steps only when the
replacement segment remains navigable in the available masks. The planner does
not substitute an unchecked straight line when a search fails.

## Antimeridian Handling

The global grid wraps east to west, and geodesic calculations use wrapped
longitude deltas. Public `routePolylines` split renderable geometry at ±180°,
while ``MaritimeMapViewport`` fits longitude on a circle.
