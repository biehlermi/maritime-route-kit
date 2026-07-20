# Canals and Connectors

Understand the explicitly represented artificial passages.

## Supported Connectors

The bundled graph includes high-detail water masks and passage metadata for:

- Suez Canal
- Panama Canal

The planner considers these connections automatically during graph search. A
caller neither selects a canal nor needs to add a canal stop, although stops
inside represented connector areas are supported.

Connector representation establishes illustrative geometric connectivity only.
It does not model dimensions, draft, air draft, tolls, bookings, queues, convoy
rules, lock operations, opening times, maintenance, or closures.

Other canals, including the Kiel Canal, are not explicitly modeled by the
current bundled data.
