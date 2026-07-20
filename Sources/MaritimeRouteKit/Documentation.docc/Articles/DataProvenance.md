# Data Provenance

Understand the source and licensing of the bundled routing data.

## Sources

The global ocean mask is derived from Natural Earth 1:10m ocean version 5.1.1,
which is public domain. Detailed masks for selected coastal areas and connectors
are derived from OpenStreetMap data and remain covered by ODbL 1.0. The test
port catalog is derived from the NGA World Port Index.

Exact source dates, checksums, attribution, extraction notes, and license
details are recorded in `DataSources/SOURCES.md` in the repository.

## Runtime Resource

The package ships one `world.mrkroute` resource. It contains metadata, a
compressed portal graph, and independently compressed raster tiles. The
resource is read lazily and route planning does not access the network.

## Rebuilding

Use `Tools/build_water_data.py` to create intermediate grids and
`Tools/build_world_route.py` to compile the runtime container. Validate the
result with `Tools/inspect_world_route.py`. The tools use Python's standard
library; their command-line arguments and the required pinned source files are
documented in the repository README and `DataSources/SOURCES.md`.
