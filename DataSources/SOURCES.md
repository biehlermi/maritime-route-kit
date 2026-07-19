# Runtime water-data sources

The committed `.mrkgrid` files are deterministic, bit-packed derivatives used
only to decide whether an illustrative route is over water. They contain no
names, tags, or user data.

## Global ocean

- Natural Earth `ne_10m_ocean`, dataset version 5.1.1 (published 2022-05-09)
- Download: `https://naciscdn.org/naturalearth/10m/physical/ne_10m_ocean.zip`
- ZIP SHA-256: `db626fcd5d50b096b156c78a2cc95011b39f32a61b4e47d147e3f7a77b8b2719`
- Extracted SHP SHA-256: `bb5ae1e0922b02e61e14f6d562fc2299db4bef5ca36c1008b1a8e7ddf9da6410`
- Public domain; see <https://www.naturalearthdata.com/about/terms-of-use/>

## High-detail constrained waterways and connectors

The Elbe, Bergen, Geirangerfjord, and Stockholm patches are derived from
OpenStreetMap coastline and water-area geometry as it existed at
`2026-07-18T00:00:00Z`. The exact queries are committed under `Tools/queries/`.
The Suez and Panama connector extracts were retrieved on `2026-07-18`; their
exact content is pinned by the source hashes below. Those queries include canal
centerlines plus mapped canal, river, and lake areas needed to construct a
continuous passage between the configured open-water gateways.

- Elbe Overpass JSON SHA-256: `5be1dd297d8e6151e3b37917534166451e2d68a35d43517a5590fb3502e61708`
- Bergen Overpass JSON SHA-256: `232d5fe6b6061b2f40be0f8d7b8a53907bbfdfc057f7cd2cc6e11c00c1c38d7a`
- Geirangerfjord Overpass JSON SHA-256: `4beca19e520c807fe813a99dc30207a30a666a9d3bffabefc6f1c85cbd8dd861`
- Stockholm archipelago Overpass JSON SHA-256: `5b13ba747e4bc54f680a733cba28ce59e6ff51dff6c01f9f67f84d930c7edd03`
- Suez Overpass JSON SHA-256: `2a1bf439160b713b873fc01cc5a3dfb2cbec3003919d46fea1d0b24b0c90ae92`
- Panama Overpass JSON SHA-256: `0f68a4ca737b9879260fa84cc307cd68d2ccf2c5324ea1142123a0ee63930fe7`
- © OpenStreetMap contributors, available under ODbL 1.0:
  <https://www.openstreetmap.org/copyright>

The derived high-detail grids remain subject to ODbL 1.0. They are distributed
separately from the MIT-licensed Swift source.

## Rebuilding

Download/unzip the Natural Earth archive and run:

```sh
python3 Tools/build_water_data.py \
  --natural-earth-shp path/to/ne_10m_ocean.shp \
  --source elbe=path/to/elbe-water.json \
  --source bergen=path/to/bergen-coastline.json \
  --source geirangerfjord=path/to/geiranger-coastline.json \
  --source stockholm=path/to/stockholm-coastline.json \
  --source suez=path/to/suez-water.json \
  --source panama=path/to/panama-water.json \
  --output Sources/MaritimeRouteKit/Resources
```

`Tools/waterways.json` is the manifest for regional resources. A one-gateway
entry is a constrained endpoint region; a multi-gateway entry becomes a generic
connector. `linearWaterwayNames` selects relevant OSM centerlines and
`linearWaterwayWidthMeters` defines their conservative raster corridor. Runtime
grid discovery means a newly generated connector does not require a matching
Swift filename entry.

During iterative data work, rebuild selected regions while reusing the committed
global mask:

```sh
python3 Tools/build_water_data.py \
  --existing-global-grid Sources/MaritimeRouteKit/Resources/global-ocean.mrkgrid \
  --source suez=path/to/suez-water.json \
  --source panama=path/to/panama-water.json \
  --only suez \
  --only panama \
  --output Sources/MaritimeRouteKit/Resources
```

The script has no third-party Python dependencies. It validates that every
gateway is navigable and writes one deterministic direction layer per gateway.

Expected runtime-grid SHA-256 values:

- `global-ocean.mrkgrid`: `60e1cce85a752edb4965b85404f759df7012e00ce5b12f8e1c918b5922e779b8`
- `elbe.mrkgrid`: `050fe7dbdfee0b228645a3b1539d8154f4532fadb4fbeb864979ca76d674012c`
- `bergen.mrkgrid`: `1609186143ac7f6a7bd6ff4007b2e1e479afbe414a0744f7c55f7f819d645e13`
- `geirangerfjord.mrkgrid`: `a8e5b7743d02c32c463baec77233a81e75f777c37ba127d9f031939e7acc0ee8`
- `stockholm.mrkgrid`: `8890fd2622cbfa0aaafd9e7b7ce9c5c602951d4f67d74ac9c142fc69eaac166f`
- `suez.mrkgrid`: `992f452f54d9ec33afb1ef3cb8ddbb1adee1f4d5b135507bdde55cef887c22d5`
- `panama.mrkgrid`: `b7a25e0acba9bb75662f8ab369df06a62808f3258878e0b92f35d7591db3d45d`
