# Known Limitations

MaritimeRouteKit produces illustrative geometry and must not be used for
navigation.

## Geographic Detail

Outside the bundled detailed regions, the Natural Earth source scale omits
small islands, harbor basins, river approaches, and narrow passages. Inland
lakes are not connected to the ocean routing graph. A represented real-world
waterway may therefore be unavailable, and a rendered route can differ from a
route selected by a mariner.

## Static Model

The engine does not account for charted depth, under-keel clearance, vessel
dimensions or handling, shipping lanes, traffic separation schemes, pilotage,
port rules, restricted or military waters, weather, currents, tides, ice,
piracy, notices to mariners, locks, bookings, schedules, fees, maintenance, or
temporary closures.

## Placement and Presentation

Stops can move to represented water by up to the configured maximum snap
distance. Always show or otherwise account for normalized placements when that
distinction matters. MapKit basemap tiles follow normal system availability even
though route planning itself is offline.
