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

## High-detail constrained waterways

The Elbe, Bergen, Geirangerfjord, and Stockholm patches are derived from
OpenStreetMap coastline and water-area geometry as it existed at
`2026-07-18T00:00:00Z`. The exact queries are committed under `Tools/queries/`.

- Elbe Overpass JSON SHA-256: `5be1dd297d8e6151e3b37917534166451e2d68a35d43517a5590fb3502e61708`
- Bergen Overpass JSON SHA-256: `232d5fe6b6061b2f40be0f8d7b8a53907bbfdfc057f7cd2cc6e11c00c1c38d7a`
- Geirangerfjord Overpass JSON SHA-256: `4beca19e520c807fe813a99dc30207a30a666a9d3bffabefc6f1c85cbd8dd861`
- Stockholm archipelago Overpass JSON SHA-256: `5b13ba747e4bc54f680a733cba28ce59e6ff51dff6c01f9f67f84d930c7edd03`
- © OpenStreetMap contributors, available under ODbL 1.0:
  <https://www.openstreetmap.org/copyright>

The derived high-detail grids remain subject to ODbL 1.0. They are distributed
separately from the MIT-licensed Swift source.

## Rebuilding

Download/unzip the Natural Earth archive and run:

```sh
python3 Tools/build_water_data.py \
  --natural-earth-shp path/to/ne_10m_ocean.shp \
  --elbe-json path/to/elbe-water.json \
  --bergen-json path/to/bergen-coastline.json \
  --geiranger-json path/to/geiranger-coastline.json \
  --stockholm-json path/to/stockholm-coastline.json \
  --output Sources/MaritimeRouteKit/Resources
```

The script has no third-party Python dependencies.

Expected runtime-grid SHA-256 values:

- `global-ocean.mrkgrid`: `60e1cce85a752edb4965b85404f759df7012e00ce5b12f8e1c918b5922e779b8`
- `elbe.mrkgrid`: `050fe7dbdfee0b228645a3b1539d8154f4532fadb4fbeb864979ca76d674012c`
- `bergen.mrkgrid`: `1609186143ac7f6a7bd6ff4007b2e1e479afbe414a0744f7c55f7f819d645e13`
- `geirangerfjord.mrkgrid`: `a8e5b7743d02c32c463baec77233a81e75f777c37ba127d9f031939e7acc0ee8`
- `stockholm.mrkgrid`: `8890fd2622cbfa0aaafd9e7b7ce9c5c602951d4f67d74ac9c142fc69eaac166f`
