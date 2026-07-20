# Runtime routing-data sources

The package ships exactly one deterministic data container:
`Sources/MaritimeRouteKit/Resources/world.mrkroute`. It contains the worldwide
graph, spatial index metadata, compressed global and detailed water tiles, and
internal passage identifiers. It contains no names, tags, or user data.

The `.mrkgrid` files described below are reproducible build intermediates. They
are deliberately not package resources and are not required at runtime.

## Global ocean

- Natural Earth `ne_10m_ocean`, dataset version 5.1.1 (published 2022-05-09)
- Download: <https://naciscdn.org/naturalearth/10m/physical/ne_10m_ocean.zip>
- ZIP SHA-256: `db626fcd5d50b096b156c78a2cc95011b39f32a61b4e47d147e3f7a77b8b2719`
- Extracted SHP SHA-256: `bb5ae1e0922b02e61e14f6d562fc2299db4bef5ca36c1008b1a8e7ddf9da6410`
- Public domain; see <https://www.naturalearthdata.com/about/terms-of-use/>

The global intermediate has 0.025° cells and a conservative open-water land
clearance. It is the authoritative fallback outside detailed masks.

## Current high-detail water masks

The Elbe, western Norway, Trondheimsfjord, and Stockholm masks are derived from
OpenStreetMap coastline and water-area geometry as it existed at
`2026-07-18T00:00:00Z`. The Suez and Panama connector extracts were retrieved on
`2026-07-18`. Their source content is pinned by these SHA-256 values:

- Elbe Overpass JSON: `5be1dd297d8e6151e3b37917534166451e2d68a35d43517a5590fb3502e61708`
- Southern Norway Overpass JSON: `1246547ad81c87b7650028ad9ddbb28f24bbe3af7f125fe8dce48d10f3f0549e`
- Central Norway Overpass JSON: `ede7e21b2e2cba263be6b84cf0ef706e9da460151dd4677f60c6e671ee5d64eb`
- Trondheimsfjord Overpass JSON: `8cb7b0ce42d90b0ae243dd0315c4a7fa6c39daa00137cdc8eff8a7df56915ab4`
- Stockholm archipelago Overpass JSON: `5b13ba747e4bc54f680a733cba28ce59e6ff51dff6c01f9f67f84d930c7edd03`
- Suez Overpass JSON: `2a1bf439160b713b873fc01cc5a3dfb2cbec3003919d46fea1d0b24b0c90ae92`
- Panama Overpass JSON: `0f68a4ca737b9879260fa84cc307cd68d2ccf2c5324ea1142123a0ee63930fe7`
- © OpenStreetMap contributors, ODbL 1.0:
  <https://www.openstreetmap.org/copyright>

The detailed masks use the source water polygons plus configured canal
centerlines where mapped polygons are incomplete. `Tools/waterways.json` pins
bounds, gateways, source-selection rules, and assumed centerline widths.
Detailed water is filtered to components that can reach an ocean transfer, so
unrelated lakes are not shipped.

The ODbL-covered derived data remains separate from the MIT-licensed Swift
source.

## Port acceptance fixtures

`Tests/MaritimeRouteKitTests/Resources/worldwide_ports.json` contains 600
globally distributed test coordinates selected deterministically from the NGA
World Port Index `UpdatedPub150.csv`. The catalog is test input only; it is not
used by the planner and does not limit the coordinates callers may pass.

- Source SHA-256: `299ad0963f07a0354b42997825aa30ac360c936537bc3a1a2091b379de397a9f`
- Publisher and current downloads: <https://msi.nga.mil/Publications/WPI>

## Rebuilding

Create the deterministic intermediate masks outside the package resources:

```sh
python3 Tools/build_water_data.py \
  --natural-earth-shp path/to/ne_10m_ocean.shp \
  --source elbe=path/to/elbe-water.json \
  --source norway-south=path/to/norway-south-coastline.json \
  --source norway-central=path/to/norway-central-coastline.json \
  --source trondheimsfjord=path/to/trondheimsfjord-coastline.json \
  --source stockholm=path/to/stockholm-coastline.json \
  --source suez=path/to/suez-water.json \
  --source panama=path/to/panama-water.json \
  --output path/to/intermediate-grids
```

Compile the intermediates into the single package resource and validate every
compressed block, checksum, graph bound, CSR offset, tile index, and size gate:

```sh
python3 Tools/build_world_route.py \
  --grid-directory path/to/intermediate-grids \
  --output Sources/MaritimeRouteKit/Resources/world.mrkroute

python3 Tools/inspect_world_route.py \
  Sources/MaritimeRouteKit/Resources/world.mrkroute
```

The builder flood-fills regional masks from their transfers, creates 128×128
tiles, encodes uniform land/water tiles as payload-free flags, and independently
raw-DEFLATE-compresses mixed tiles. It derives a deterministic hierarchical
portal graph in flat CSR form and rejects disconnected declared gateways. The
builder and inspector both enforce the 25 MiB installed-size ceiling.

Identical source files and manifest settings produce byte-identical output.
The committed container is 5,833,346 bytes with SHA-256
`77430acaf3164dee57bc00a5d5101e6c198c72ca331e066334979f3bc0d5d3bc`.

For the WPI fixture catalog:

```sh
python3 Tools/build_port_fixtures.py \
  --source path/to/UpdatedPub150.csv \
  --global-grid path/to/intermediate-grids/global-ocean.mrkgrid \
  --output Tests/MaritimeRouteKitTests/Resources/worldwide_ports.json \
  --count 600
```

## Coverage boundary

The container architecture and routing logic support arbitrary additional
detailed regions without Swift changes. This committed dataset currently has
high detail for Elbe/Hamburg, western Norway from Haugesund through
Trondheimsfjord, Stockholm, Suez, and Panama. Other ocean-connected coordinates
use the coarser Natural Earth mask; Kotor, Kiel Canal, and other narrow passages
still require pinned OSM source data and regenerated detailed tiles.
