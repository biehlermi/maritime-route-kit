# MaritimeRouteKit agent guide

These instructions apply to the entire repository. They are written for coding
agents that need to extend the offline routing dataset, especially when a real
coastal port or narrow waterway is missing from the coarse worldwide mask.

## Non-negotiable routing rules

- MaritimeRouteKit produces illustrative, offline water geometry. Never describe
  it as suitable for navigation.
- Do not fix missing coverage by returning a straight line, accepting a segment
  that crosses represented land, weakening `validate`, or silently dropping a
  diagnostic.
- Do not increase the public 25 km snap ceiling to hide a missing regional mask.
- Keep the runtime offline. Network access is allowed only while creating pinned
  build inputs; request the required approval before downloading anything.
- Do not commit large Overpass JSON or `.mrkgrid` intermediates. Commit the query,
  manifest entry, tests, provenance, and regenerated `world.mrkroute`.
- Preserve the 25 MiB installed-resource limit enforced by the builders.

## Understand the data model before changing it

The shipped `Sources/MaritimeRouteKit/Resources/world.mrkroute` contains:

1. One 0.025° Natural Earth global ocean grid. It is intentionally conservative
   and cannot represent many fjords, archipelagos, harbors, and river approaches.
2. Finer `constrained` regional grids built from OpenStreetMap coastline and
   water-area geometry.
3. Fine `connector` grids for passages such as Suez and Panama.
4. One portal graph that connects every regional gateway to a navigable cell in
   the global grid.

A constrained grid retains only water connected to one of its declared
gateways. This prevents inland lakes and unrelated polygons from being shipped.
Regional grids do **not** connect directly merely because their bounds overlap;
each one transfers through its declared global-water gateway. Small overlaps are
useful as buffers, but they can change which grid wins endpoint placement, so
cross-region legs must be tested.

The usual symptom mapping is:

| Diagnostic | Likely cause |
| --- | --- |
| `stopCannotBePlaced` | No retained water cell is within the snap limit. The port may be outside detailed bounds, erased by resolution/clearance, or disconnected from the gateway. |
| `legCannotBeRouted` after both stops were placed | The placements belong to graph components that do not connect, often because one stop used an isolated coarse Natural Earth water polygon. |
| Builder says a gateway is not navigable | The gateway is on land, too near shore after erosion, outside the source-derived water, or outside the bounds. |
| Builder says a gateway does not overlap global water | The regional gateway is water, but the Natural Earth grid's 2 km-eroded cell is not. Move the gateway farther into represented open sea. |
| A focused test reports zero tests | A Swift Testing identifier was passed without the trailing `()`; enumerate tests or use the exact identifier. |

## Coverage-expansion workflow

Follow every numbered step. Iteration may use partial builds, but the final asset
must come from a clean build of all pinned raw inputs.

### 1. Reproduce the exact failure first

Add a focused regression with the caller's exact coordinates and itinerary
order before changing data. Assert all three contracts:

```swift
@Test("A western Norway itinerary routes through every requested fjord port")
func westernNorwayItinerary() async throws {
  let stops = [
    stop("bergen", "Bergen", 60.401799065948644, 5.309421440417016),
    stop("alesund", "Ålesund", 62.4722, 6.1549),
    stop("geiranger", "Geiranger", 62.1015, 7.205),
    stop("molde", "Molde", 62.7375, 7.1591),
    stop("maloy", "Måløy", 61.9353, 5.1136),
    stop("flam", "Flåm", 60.8628, 7.1138),
    stop("haugesund", "Haugesund", 59.4138, 5.2677),
  ]

  let result = await MaritimeRoutePlanner().plan(stops: stops)
  #expect(result.placements.allSatisfy { $0.status == .placed })
  #expect(result.legs.map(\.startIndex) == Array(0..<(stops.count - 1)))
  #expect(result.diagnostics.isEmpty)
  for leg in result.legs { try assertEverySegmentIsWaterSafe(leg) }
}
```

Record the pre-fix diagnostics. For the Flåm case, Flåm could not be placed and
the Geiranger–Molde and Molde–Måløy legs used disconnected coarse components.
Also reproduce additional stops visible in screenshots even if they were omitted
from the written coordinate list. That is why the Norway fix separately tests
Geiranger–Trondheim–Molde.

### 2. Choose coherent regional bounds

Bounds must include:

- every requested port;
- the full water corridor from each port to the sea;
- a modest buffer around the coastline and across tile boundaries; and
- at least one open-sea gateway that is navigable in both the regional and
  global grids.

Do not reflexively make one country-sized Overpass query. Coastlines can be very
detailed. The original one-piece western-Norway request repeatedly timed out;
the reliable fix used three coherent basins:

```json
{
  "name": "norway-south",
  "kind": "constrained",
  "bounds": [58.90, 4.15, 61.55, 8.25],
  "gateways": [[59.05, 4.25]],
  "step": 0.001
},
{
  "name": "norway-central",
  "kind": "constrained",
  "bounds": [61.40, 4.55, 63.00, 8.30],
  "gateways": [[62.80, 4.65]],
  "step": 0.001
},
{
  "name": "trondheimsfjord",
  "kind": "constrained",
  "bounds": [62.75, 7.40, 64.00, 11.20],
  "gateways": [[63.70, 7.50]],
  "step": 0.001
}
```

At Norwegian latitudes, a 0.001° cell is about 111 m north-south and roughly
50 m east-west. The erosion code removes at least one cell on every side, so
resolution directly controls which narrow channels survive. Use 0.0005° for a
small or especially narrow passage. Prefer tighter bounds over an unnecessarily
fine, enormous grid. After choosing a resolution, test every important narrow
approach rather than assuming the raster preserved it.

One gateway is sufficient when all desired regional water belongs to one ocean
component. Add multiple gateways only for genuinely separate entrances or
components. Every extra gateway creates another direction layer in the
intermediate grid.

### 3. Add a pinned Overpass query for each manifest region

The query filename should match the manifest name:

```text
Tools/queries/norway-south.overpassql
Tools/queries/norway-central.overpassql
Tools/queries/trondheimsfjord.overpassql
```

For a coastline region, use a fixed historical timestamp, generous server-side
limits, and the exact manifest bounds:

```overpass
[out:json][timeout:600][maxsize:1073741824][date:"2026-07-18T00:00:00Z"];
way["natural"="coastline"](58.90,4.15,61.55,8.25);
out geom;
```

Never remove `[date:...]` just to make a request faster; an unpinned live query
cannot reproduce the committed resource. For a river, canal, or incomplete
coastline, query the relevant water areas as well. Follow
`Tools/queries/elbe.overpassql` for river polygons and relations, or the Suez and
Panama queries for canal features. If centerlines are required, add explicit
`linearWaterwayNames`, `linearWaterwayWidthMeters`, and
`connectGatewaysToLinearWaterways` settings in `Tools/waterways.json`; do not
invent corridors without documenting the assumption.

### 4. Download, validate, and hash the unshipped source extracts

Use a currently listed public Overpass instance, a unique `User-Agent`, raw-query
POST format, and an explicit temporary destination. Ask for network approval
first. Example:

```sh
curl --fail --show-error --silent --max-time 900 \
  --user-agent MaritimeRouteKit-data-builder/1.0 \
  --data-binary @Tools/queries/norway-south.overpassql \
  --output /private/tmp/norway-south-coastline.json \
  https://overpass-api.de/api/interpreter

python3 -m json.tool /private/tmp/norway-south-coastline.json >/dev/null
shasum -a 256 /private/tmp/norway-south-coastline.json
```

Large coastline extracts may return HTTP 504 even with a high query timeout.
Use another currently documented public instance or split the bounds into
coherent regional grids. Do not hammer one public endpoint with retries, and do
not combine differently dated responses. The successful Norway source files
were approximately 97 MB south, 36 MB central, and 71 MB for Trondheimsfjord;
those large files remain outside Git.

Add the exact timestamp, SHA-256, OpenStreetMap attribution, and source purpose
to `DataSources/SOURCES.md` immediately. A hash is part of the reproducibility
contract, not an optional note.

### 5. Validate gateways before spending time on the world graph

Prefer gateway points well offshore and comfortably inside the regional bounds.
They must survive both the regional clearance and the coarser global grid's
2 km clearance.

If an existing clean `global-ocean.mrkgrid` is available, a quick global-cell
check can be made with the helpers in `Tools/build_water_data.py`. This only
checks the global half of the transfer; the regional build remains authoritative:

```sh
python3 -c 'from math import floor; from pathlib import Path; from Tools.build_water_data import bit_is_set, read_grid_mask; rows, meta = read_grid_mask(Path("/private/tmp/global-ocean.mrkgrid")); lat, lon = 59.05, 4.25; step = float(meta["step"]); row = floor((lat - float(meta["minLatitude"])) / step); col = floor((lon - float(meta["minLongitude"])) / step); print(bit_is_set(rows, row, col))'
```

Then build only the new region to catch source, erosion, and gateway errors
quickly:

```sh
python3 Tools/build_water_data.py \
  --existing-global-grid /private/tmp/global-ocean.mrkgrid \
  --only norway-south \
  --source norway-south=/private/tmp/norway-south-coastline.json \
  --output /private/tmp/norway-region-check
```

Do not treat this partial build as the final reproducible asset.

### 6. Perform the final clean build from every pinned raw input

Do not copy old `.mrkgrid` files from DerivedData or a previous build into the
final input directory. Even when their water bits are unchanged, legacy metadata
can change the final resource checksum. The Norway work exposed exactly this
problem with older Elbe and Stockholm intermediate metadata.

Create a new explicit temporary directory and rebuild every grid:

```sh
coverage_work_dir="$(mktemp -d /private/tmp/mrk-coverage.XXXXXX)"

python3 Tools/build_water_data.py \
  --natural-earth-shp /path/to/ne_10m_ocean.shp \
  --source elbe=/path/to/elbe-water.json \
  --source norway-south=/private/tmp/norway-south-coastline.json \
  --source norway-central=/private/tmp/norway-central-coastline.json \
  --source trondheimsfjord=/private/tmp/trondheimsfjord-coastline.json \
  --source stockholm=/path/to/stockholm-coastline.json \
  --source suez=/path/to/suez-water.json \
  --source panama=/path/to/panama-water.json \
  --output "$coverage_work_dir"

python3 Tools/build_world_route.py \
  --grid-directory "$coverage_work_dir" \
  --output /private/tmp/world-candidate.mrkroute

python3 Tools/inspect_world_route.py /private/tmp/world-candidate.mrkroute
shasum -a 256 /private/tmp/world-candidate.mrkroute
```

The world builder must complete gateway-connectivity validation. The inspector
must report all gateway nodes in one routed component, a valid compressed graph,
and fewer than 26,214,400 bytes. Only after those checks pass should the generated
candidate replace:

```text
Sources/MaritimeRouteKit/Resources/world.mrkroute
```

Re-run the clean build or otherwise compare independent clean outputs when the
checksum is unexpectedly different. Do not update the documented checksum until
the clean full build is the file in the package.

### 7. Run focused tests correctly

Swift Testing identifiers include parentheses. First enumerate if uncertain:

```sh
xcodebuild -scheme MaritimeRouteKit \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  test -enumerate-tests \
  -test-enumeration-style flat \
  -test-enumeration-format json
```

Then use the exact identifier:

```sh
xcodebuild -scheme MaritimeRouteKit \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -enableCodeCoverage NO test \
  '-only-testing:MaritimeRouteKitTests/MaritimeRoutePlannerTests/westernNorwayItinerary()'
```

Verify the log says that one test ran. `TEST SUCCEEDED` with "0 tests" proves
nothing. Each coverage regression must assert:

- every requested stop is placed;
- every consecutive leg index is present;
- diagnostics are empty; and
- every returned segment passes `WaterWorld.isNavigableSegment` through the
  existing `assertEverySegmentIsWaterSafe` helper.

Test cross-region legs in both relevant directions when gateway composition or
overlap is involved. Also retain representative old tests such as
Hamburg–Bergen and Hamburg–Geiranger to catch regressions outside the new ports.

### 8. Run the complete and release-performance suites

After focused tests pass, run the entire simulator suite against the final
resource:

```sh
xcodebuild -scheme MaritimeRouteKit \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -enableCodeCoverage NO test
```

The portal graph and installed resource changed, so also run the optimized gate:

```sh
xcodebuild -scheme MaritimeRouteKit \
  -configuration Release \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -enableCodeCoverage NO \
  ENABLE_TESTABILITY=YES test \
  '-only-testing:MaritimeRouteKitTests/ReleasePerformanceTests/routingGates()'
```

For the Norway expansion, the final verification baseline was 29 tests in three
debug suites plus the release routing-performance test.

### 9. Update every reproducibility surface

Before handing off, update all of the following:

- `Tools/waterways.json`: bounds, kind, gateways, resolution, and any documented
  centerline assumptions.
- `Tools/queries/<region>.overpassql`: committed pinned query for every new
  source binding.
- `DataSources/SOURCES.md`: snapshot date, input hashes, attribution, rebuild
  command, coverage boundary, final byte count, and final resource SHA-256.
- `README.md`: current detailed-coverage summary, complete rebuild example, and
  approximate installed size.
- `Tests/MaritimeRouteKitTests/MaritimeRouteKitTests.swift`: exact reported
  itinerary and any screenshot-only legs.
- `Tools/build_water_data.py`: remove stale named convenience flags if the
  regions they referenced were replaced. The generic repeatable `--source`
  binding is preferred for new regions.

Finally run:

```sh
git diff --check
python3 -m json.tool Tools/waterways.json >/dev/null
python3 Tools/inspect_world_route.py \
  Sources/MaritimeRouteKit/Resources/world.mrkroute
```

If Python cannot write its default bytecode cache in the sandbox, set a
task-specific prefix such as
`PYTHONPYCACHEPREFIX=/private/tmp/mrk-pycache`; never repurpose `HOME`.

## Troubleshooting without weakening correctness

- **A port still cannot be placed:** inspect whether it lies inside the intended
  bounds, whether the coastline query includes the whole fjord, and whether its
  water component can flood-fill to a gateway. Try a finer step or corrected
  bounds; do not increase snap distance first.
- **Both ports place but the leg fails:** inspect each placement's grid and graph
  access. Add detail for the missing corridor or replace an isolated coarse
  component with an ocean-connected regional mask.
- **A narrow channel disappeared:** the one-cell minimum erosion is large at a
  coarse step. Tighten bounds and decrease `step`, then rebuild and revalidate.
- **An Overpass request times out:** split the geography along coherent ocean
  basins, try a currently documented public instance, and keep the same pinned
  date. Never switch silently to live data.
- **A route validates against the wrong detail grid:** reduce unnecessary
  overlap or ensure both endpoints and transfer approaches are water-safe in the
  finest overlapping grid. Placement prefers the closest cell, then finer step,
  then lower grid index.
- **The resource grows too much:** crop unused inland/open-sea bounds, use the
  coarsest step that preserves the required passages, and inspect graph-node and
  mixed-tile growth. Do not raise the 25 MiB ceiling casually.
- **The final hash differs from an iterative build:** discard reused
  intermediates and perform the full clean build. Metadata is part of every
  `.mrkgrid` hash even when water bits are identical.

The goal is not merely to make one screenshot draw a line. The completed change
must be pinned, cleanly reproducible, ocean-connected, land-safe, compact, and
covered by exact itinerary regressions.
