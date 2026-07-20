#!/usr/bin/env python3
"""Build MaritimeRouteKit's compact offline water grids.

The script intentionally uses only Python's standard library. It consumes the
version-pinned Natural Earth ocean shapefile and checksum-pinned Overpass JSON
extracts described in DataSources/SOURCES.md.
"""

from __future__ import annotations

import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
import struct
from typing import Iterable, Sequence


MAGIC = b"MRKGRID1"
EARTH_KM_PER_DEGREE = 111.195


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_polygon_shapefile(path: Path) -> list[list[tuple[float, float]]]:
    rings: list[list[tuple[float, float]]] = []
    with path.open("rb") as handle:
        if len(handle.read(100)) != 100:
            raise ValueError(f"Invalid shapefile header: {path}")
        while header := handle.read(8):
            if len(header) != 8:
                raise ValueError(f"Truncated record header: {path}")
            _, content_words = struct.unpack(">2i", header)
            content = handle.read(content_words * 2)
            shape_type = struct.unpack_from("<i", content)[0]
            if shape_type == 0:
                continue
            if shape_type not in (5, 15, 25):
                raise ValueError(f"Expected polygon shapefile, got type {shape_type}")
            part_count, point_count = struct.unpack_from("<2i", content, 36)
            starts = list(struct.unpack_from(f"<{part_count}i", content, 44))
            starts.append(point_count)
            point_offset = 44 + part_count * 4
            points = [
                struct.unpack_from("<2d", content, point_offset + index * 16)
                for index in range(point_count)
            ]
            rings.extend(points[starts[i] : starts[i + 1]] for i in range(part_count))
    return rings


def scanline_mask(
    rings: Iterable[Sequence[tuple[float, float]]],
    *,
    min_latitude: float,
    min_longitude: float,
    step: float,
    rows: int,
    columns: int,
) -> list[int]:
    intersections: list[list[float]] = [[] for _ in range(rows)]
    max_latitude = min_latitude + rows * step

    for ring in rings:
        if len(ring) < 3:
            continue
        previous_x, previous_y = ring[-1]
        for x, y in ring:
            if y != previous_y:
                low_y = max(min(y, previous_y), min_latitude)
                high_y = min(max(y, previous_y), max_latitude)
                first_row = max(0, math.ceil((low_y - min_latitude) / step - 0.5))
                last_row = min(rows - 1, math.ceil((high_y - min_latitude) / step - 0.5) - 1)
                for row in range(first_row, last_row + 1):
                    sample_y = min_latitude + (row + 0.5) * step
                    fraction = (sample_y - previous_y) / (y - previous_y)
                    intersections[row].append(previous_x + fraction * (x - previous_x))
            previous_x, previous_y = x, y

    masks: list[int] = []
    for xs in intersections:
        xs.sort()
        row_mask = 0
        for index in range(0, len(xs) - 1, 2):
            left, right = xs[index], xs[index + 1]
            first_column = max(0, math.ceil((left - min_longitude) / step - 0.5))
            last_column = min(columns - 1, math.ceil((right - min_longitude) / step - 0.5) - 1)
            if last_column >= first_column:
                width = last_column - first_column + 1
                row_mask |= ((1 << width) - 1) << first_column
        masks.append(row_mask)
    return masks


def erode_mask(
    rows_mask: Sequence[int],
    *,
    min_latitude: float,
    step: float,
    columns: int,
    clearance_meters: float,
    wrap_longitude: bool = False,
) -> list[int]:
    full_row = (1 << columns) - 1
    vertical_radius = max(1, math.ceil(clearance_meters / (step * EARTH_KM_PER_DEGREE * 1000)))
    horizontally_eroded: list[int] = []

    for row, original in enumerate(rows_mask):
        latitude = min_latitude + (row + 0.5) * step
        column_meters = max(1.0, step * EARTH_KM_PER_DEGREE * 1000 * abs(math.cos(math.radians(latitude))))
        horizontal_radius = max(1, math.ceil(clearance_meters / column_meters))
        value = original
        for offset in range(1, horizontal_radius + 1):
            if wrap_longitude:
                rotated_left = ((original << offset) & full_row) | (original >> (columns - offset))
                rotated_right = (original >> offset) | ((original << (columns - offset)) & full_row)
                value &= rotated_left
                value &= rotated_right
            else:
                value &= (original << offset) & full_row
                value &= original >> offset
        horizontally_eroded.append(value)

    result: list[int] = []
    for row, value in enumerate(horizontally_eroded):
        for offset in range(1, vertical_radius + 1):
            above = row - offset
            below = row + offset
            if above < 0 or below >= len(rows_mask):
                value = 0
                break
            value &= horizontally_eroded[above]
            value &= horizontally_eroded[below]
        result.append(value)
    return result


def bit_is_set(rows_mask: Sequence[int], row: int, column: int) -> bool:
    return 0 <= row < len(rows_mask) and column >= 0 and bool(rows_mask[row] & (1 << column))


def draw_barriers(
    lines: Iterable[Sequence[tuple[float, float]]],
    *,
    min_latitude: float,
    min_longitude: float,
    step: float,
    rows: int,
    columns: int,
) -> bytearray:
    barriers = bytearray(rows * columns)
    for line in lines:
        if len(line) < 2:
            continue
        previous_x, previous_y = line[0]
        for x, y in line[1:]:
            dx = (x - previous_x) / step
            dy = (y - previous_y) / step
            sample_count = max(1, math.ceil(max(abs(dx), abs(dy)) * 3))
            for sample in range(sample_count + 1):
                fraction = sample / sample_count
                longitude = previous_x + (x - previous_x) * fraction
                latitude = previous_y + (y - previous_y) * fraction
                column = math.floor((longitude - min_longitude) / step)
                row = math.floor((latitude - min_latitude) / step)
                if 0 <= row < rows and 0 <= column < columns:
                    barriers[row * columns + column] = 1
            previous_x, previous_y = x, y
    return barriers


def overpass_geometry(
    path: Path,
    *,
    linear_waterway_names: set[str] | None = None,
) -> tuple[
    list[list[tuple[float, float]]],
    list[list[tuple[float, float]]],
    list[list[tuple[float, float]]],
]:
    payload = json.loads(path.read_text())
    coastlines: list[list[tuple[float, float]]] = []
    water_rings: list[list[tuple[float, float]]] = []
    water_lines: list[list[tuple[float, float]]] = []

    def points(geometry: Sequence[dict[str, float]]) -> list[tuple[float, float]]:
        return [(point["lon"], point["lat"]) for point in geometry]

    def assemble(lines: list[list[tuple[float, float]]]) -> list[list[tuple[float, float]]]:
        remaining = [line for line in lines if len(line) > 1]
        rings: list[list[tuple[float, float]]] = []
        while remaining:
            ring = remaining.pop()
            made_progress = True
            while ring[0] != ring[-1] and made_progress:
                made_progress = False
                for index, line in enumerate(remaining):
                    if ring[-1] == line[0]:
                        ring.extend(line[1:])
                    elif ring[-1] == line[-1]:
                        ring.extend(reversed(line[:-1]))
                    elif ring[0] == line[-1]:
                        ring = line[:-1] + ring
                    elif ring[0] == line[0]:
                        ring = list(reversed(line[1:])) + ring
                    else:
                        continue
                    remaining.pop(index)
                    made_progress = True
                    break
            if len(ring) >= 4 and ring[0] == ring[-1]:
                rings.append(ring)
        return rings

    for element in payload["elements"]:
        tags = element.get("tags", {})
        geometry = element.get("geometry")
        if tags.get("natural") == "coastline" and geometry:
            coastlines.append(points(geometry))
        if tags.get("waterway") in {"canal", "river"} and geometry:
            english_name = tags.get("name:en")
            if linear_waterway_names is None or english_name in linear_waterway_names:
                line = points(geometry)
                if len(line) > 1 and line[0] != line[-1]:
                    water_lines.append(line)
        is_river_area = (
            (tags.get("natural") == "water" and tags.get("water") in {"river", "canal"})
            or tags.get("waterway") == "riverbank"
        )
        if not is_river_area:
            continue
        if geometry and len(geometry) >= 4:
            ring = points(geometry)
            if ring[0] == ring[-1]:
                water_rings.append(ring)
        member_lines = [
            points(member["geometry"])
            for member in element.get("members", [])
            if member.get("role") == "outer" and member.get("geometry")
        ]
        water_rings.extend(assemble(member_lines))
    return coastlines, water_rings, water_lines


def add_waterway_corridors(
    rows_mask: Sequence[int],
    lines: Iterable[Sequence[tuple[float, float]]],
    *,
    min_latitude: float,
    min_longitude: float,
    step: float,
    rows: int,
    columns: int,
    width_meters: float,
) -> list[int]:
    """Rasterize mapped centerlines as conservative, configurable water corridors."""
    result = list(rows_mask)
    half_width = width_meters / 2
    if half_width <= 0:
        return result

    def paint(latitude: float, longitude: float) -> None:
        center_row = math.floor((latitude - min_latitude) / step)
        center_column = math.floor((longitude - min_longitude) / step)
        row_meters = step * EARTH_KM_PER_DEGREE * 1000
        column_meters = max(1.0, row_meters * abs(math.cos(math.radians(latitude))))
        row_radius = max(1, math.ceil(half_width / row_meters))
        column_radius = max(1, math.ceil(half_width / column_meters))
        for row_offset in range(-row_radius, row_radius + 1):
            row = center_row + row_offset
            if not 0 <= row < rows:
                continue
            for column_offset in range(-column_radius, column_radius + 1):
                column = center_column + column_offset
                if not 0 <= column < columns:
                    continue
                distance = math.hypot(row_offset * row_meters, column_offset * column_meters)
                if distance <= half_width + math.hypot(row_meters, column_meters) / 2:
                    result[row] |= 1 << column

    for line in lines:
        if len(line) < 2:
            continue
        previous_longitude, previous_latitude = line[0]
        for longitude, latitude in line[1:]:
            row_delta = (latitude - previous_latitude) / step
            column_delta = (longitude - previous_longitude) / step
            samples = max(1, math.ceil(max(abs(row_delta), abs(column_delta)) * 3))
            for sample in range(samples + 1):
                fraction = sample / samples
                paint(
                    previous_latitude + (latitude - previous_latitude) * fraction,
                    previous_longitude + (longitude - previous_longitude) * fraction,
                )
            previous_longitude, previous_latitude = longitude, latitude
    return result


def connect_gateways_to_lines(
    lines: Sequence[Sequence[tuple[float, float]]],
    gateways: Sequence[tuple[float, float]],
) -> list[list[tuple[float, float]]]:
    """Extend source-derived centerlines to configured open-water gateway cells."""
    points = [point for line in lines for point in line]
    if not points:
        raise ValueError("A connector grid needs at least one mapped linear waterway")
    connections: list[list[tuple[float, float]]] = []
    for latitude, longitude in gateways:
        nearest = min(
            points,
            key=lambda point: (
                (point[1] - latitude) ** 2
                + ((point[0] - longitude) * math.cos(math.radians(latitude))) ** 2
            ),
        )
        connections.append([(longitude, latitude), nearest])
    return connections


def regional_water_mask(
    coastlines: Sequence[Sequence[tuple[float, float]]],
    water_rings: Sequence[Sequence[tuple[float, float]]],
    global_ocean: Sequence[int],
    *,
    global_step: float,
    min_latitude: float,
    min_longitude: float,
    step: float,
    rows: int,
    columns: int,
    include_global_water: bool = True,
) -> list[int]:
    # Coastline ways need not form closed polygons within a regional extract.
    # Classify each scanline from the directed land-left/water-right coastline;
    # fall back to Natural Earth only for rows with no coastline crossing.
    intersections: list[list[tuple[float, bool]]] = [[] for _ in range(rows)]
    max_latitude = min_latitude + rows * step
    for line in coastlines:
        if len(line) < 2:
            continue
        previous_x, previous_y = line[0]
        for x, y in line[1:]:
            if y != previous_y:
                low_y = max(min(y, previous_y), min_latitude)
                high_y = min(max(y, previous_y), max_latitude)
                first_row = max(0, math.ceil((low_y - min_latitude) / step - 0.5))
                last_row = min(rows - 1, math.ceil((high_y - min_latitude) / step - 0.5) - 1)
                for row in range(first_row, last_row + 1):
                    sample_y = min_latitude + (row + 0.5) * step
                    fraction = (sample_y - previous_y) / (y - previous_y)
                    crossing_x = previous_x + fraction * (x - previous_x)
                    # OSM coastline ways are directed with land on the left and
                    # water on the right. Moving east across a northbound edge
                    # enters water; a southbound edge enters land.
                    intersections[row].append((crossing_x, y > previous_y))
            previous_x, previous_y = x, y

    if not include_global_water:
        coastline_water = [0] * rows
    else:
        coastline_water = []
    global_columns = round(360 / global_step)
    for row, crossings in (enumerate(intersections) if include_global_water else []):
        crossings.sort(key=lambda item: item[0])
        latitude = min_latitude + (row + 0.5) * step
        global_row = math.floor((latitude + 90.0) / global_step)
        global_column = math.floor((min_longitude + step * 0.5 + 180.0) / global_step) % global_columns
        is_water = not crossings[0][1] if crossings else bit_is_set(global_ocean, global_row, global_column)
        cursor = min_longitude
        row_mask = 0
        for crossing, water_to_east in crossings:
            clipped_crossing = min(min_longitude + columns * step, max(min_longitude, crossing))
            if is_water and clipped_crossing > cursor:
                first_column = max(0, math.ceil((cursor - min_longitude) / step - 0.5))
                last_column = min(columns - 1, math.ceil((clipped_crossing - min_longitude) / step - 0.5) - 1)
                if last_column >= first_column:
                    row_mask |= ((1 << (last_column - first_column + 1)) - 1) << first_column
            if min_longitude <= crossing <= min_longitude + columns * step:
                is_water = water_to_east
            cursor = max(cursor, clipped_crossing)
        if is_water and cursor < min_longitude + columns * step:
            first_column = max(0, math.ceil((cursor - min_longitude) / step - 0.5))
            if first_column < columns:
                row_mask |= ((1 << (columns - first_column)) - 1) << first_column
        coastline_water.append(row_mask)

    polygon_mask = scanline_mask(
        water_rings,
        min_latitude=min_latitude,
        min_longitude=min_longitude,
        step=step,
        rows=rows,
        columns=columns,
    )
    return [coastline_water[row] | polygon_mask[row] for row in range(rows)]


def gateway_directions(
    rows_mask: Sequence[int],
    *,
    min_latitude: float,
    min_longitude: float,
    step: float,
    rows: int,
    columns: int,
    gateway: tuple[float, float],
) -> bytearray:
    directions = bytearray([15]) * (rows * columns)
    gateway_row = math.floor((gateway[0] - min_latitude) / step)
    gateway_column = math.floor((gateway[1] - min_longitude) / step)
    if not bit_is_set(rows_mask, gateway_row, gateway_column):
        raise ValueError(f"Gateway {gateway} is not navigable")
    gateway_index = gateway_row * columns + gateway_column
    directions[gateway_index] = 8
    queue = array("I", [gateway_index])
    cursor = 0
    offsets = [(-1, 0), (-1, 1), (0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1)]
    while cursor < len(queue):
        index = queue[cursor]
        cursor += 1
        row, column = divmod(index, columns)
        for direction, (row_offset, column_offset) in enumerate(offsets):
            next_row = row + row_offset
            next_column = column + column_offset
            if not (0 <= next_row < rows and 0 <= next_column < columns):
                continue
            if row_offset and column_offset and (
                not bit_is_set(rows_mask, row + row_offset, column)
                or not bit_is_set(rows_mask, row, column + column_offset)
            ):
                continue
            next_index = next_row * columns + next_column
            if directions[next_index] != 15 or not bit_is_set(rows_mask, next_row, next_column):
                continue
            directions[next_index] = (direction + 4) % 8
            queue.append(next_index)
    return directions


def write_grid(
    path: Path,
    rows_mask: Sequence[int],
    metadata: dict[str, object],
    direction_layers: Sequence[bytearray] = (),
) -> None:
    columns = int(metadata["columns"])
    row_bytes = (columns + 7) // 8
    encoded_metadata = json.dumps(metadata, sort_keys=True, separators=(",", ":")).encode()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        handle.write(MAGIC)
        handle.write(struct.pack("<I", len(encoded_metadata)))
        handle.write(encoded_metadata)
        for row in rows_mask:
            handle.write(row.to_bytes(row_bytes, "little"))
        for directions in direction_layers:
            packed = bytearray((len(directions) + 1) // 2)
            for index, direction in enumerate(directions):
                packed[index // 2] |= direction << (4 * (index % 2))
            handle.write(packed)


def read_grid_mask(path: Path) -> tuple[list[int], dict[str, object]]:
    data = path.read_bytes()
    if len(data) < 12 or data[:8] != MAGIC:
        raise ValueError(f"Invalid MRK grid: {path}")
    metadata_length = struct.unpack_from("<I", data, 8)[0]
    metadata_end = 12 + metadata_length
    metadata = json.loads(data[12:metadata_end])
    columns = int(metadata["columns"])
    rows = int(metadata["rows"])
    row_bytes = (columns + 7) // 8
    water_end = metadata_end + rows * row_bytes
    if water_end > len(data):
        raise ValueError(f"Truncated MRK grid: {path}")
    rows_mask = [
        int.from_bytes(data[metadata_end + row * row_bytes : metadata_end + (row + 1) * row_bytes], "little")
        for row in range(rows)
    ]
    return rows_mask, metadata


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--natural-earth-shp", type=Path)
    parser.add_argument("--existing-global-grid", type=Path)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path(__file__).with_name("waterways.json"),
    )
    parser.add_argument(
        "--source",
        action="append",
        default=[],
        metavar="NAME=OVERPASS_JSON",
        help="Bind a manifest waterway name to its source extract (repeatable)",
    )
    parser.add_argument(
        "--only",
        action="append",
        default=[],
        metavar="NAME",
        help="Build only a named regional grid (repeatable)",
    )
    # Keep the original flags as source-binding conveniences.
    parser.add_argument("--elbe-json", type=Path)
    parser.add_argument("--stockholm-json", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if bool(args.natural_earth_shp) == bool(args.existing_global_grid):
        parser.error("provide exactly one of --natural-earth-shp or --existing-global-grid")

    source_paths: dict[str, Path] = {}
    for binding in args.source:
        if "=" not in binding:
            parser.error(f"invalid --source binding: {binding!r}")
        name, path = binding.split("=", 1)
        source_paths[name] = Path(path)
    for name, path in {
        "elbe": args.elbe_json,
        "stockholm": args.stockholm_json,
    }.items():
        if path is not None:
            source_paths[name] = path

    manifest = json.loads(args.manifest.read_text())
    if manifest.get("schemaVersion") != 1:
        raise ValueError(f"Unsupported waterway manifest: {args.manifest}")
    regions = manifest["waterways"]
    requested = set(args.only)
    known_names = {region["name"] for region in regions}
    if unknown := requested - known_names:
        parser.error(f"unknown --only waterway(s): {', '.join(sorted(unknown))}")
    selected = [region for region in regions if not requested or region["name"] in requested]

    global_step = 0.025
    if args.natural_earth_shp:
        global_rows = round(180 / global_step)
        global_columns = round(360 / global_step)
        natural_earth_rings = read_polygon_shapefile(args.natural_earth_shp)
        global_ocean = scanline_mask(
            natural_earth_rings,
            min_latitude=-90,
            min_longitude=-180,
            step=global_step,
            rows=global_rows,
            columns=global_columns,
        )
        global_safe = erode_mask(
            global_ocean,
            min_latitude=-90,
            step=global_step,
            columns=global_columns,
            clearance_meters=2000,
            wrap_longitude=True,
        )
        if not requested:
            write_grid(
                args.output / "global-ocean.mrkgrid",
                global_safe,
                {
                    "name": "Natural Earth global ocean",
                    "kind": "global",
                    "minLatitude": -90.0,
                    "minLongitude": -180.0,
                    "step": global_step,
                    "rows": global_rows,
                    "columns": global_columns,
                    "clearanceMeters": 2000,
                    "sourceSHA256": sha256(args.natural_earth_shp),
                },
            )
    else:
        global_ocean, global_metadata = read_grid_mask(args.existing_global_grid)
        if global_metadata.get("kind") != "global":
            raise ValueError("--existing-global-grid must reference the global grid")
        global_step = float(global_metadata["step"])

    for region in selected:
        name = region["name"]
        source = source_paths.get(name)
        if source is None:
            parser.error(f"missing --source {name}=OVERPASS_JSON")
        bounds = region["bounds"]
        gateways = [tuple(gateway) for gateway in region["gateways"]]
        regional_step = float(region.get("step", 0.0005))
        clearance_meters = float(region.get("clearanceMeters", 25))
        min_latitude, min_longitude, max_latitude, max_longitude = bounds
        rows = math.ceil((max_latitude - min_latitude) / regional_step)
        columns = math.ceil((max_longitude - min_longitude) / regional_step)
        configured_names = region.get("linearWaterwayNames")
        coastlines, water_rings, water_lines = overpass_geometry(
            source,
            linear_waterway_names=set(configured_names) if configured_names else None,
        )
        if region.get("connectGatewaysToLinearWaterways"):
            water_lines.extend(connect_gateways_to_lines(water_lines, gateways))
        raw_water = regional_water_mask(
            coastlines,
            water_rings,
            global_ocean,
            global_step=global_step,
            min_latitude=min_latitude,
            min_longitude=min_longitude,
            step=regional_step,
            rows=rows,
            columns=columns,
            include_global_water=bool(region.get("includeGlobalWater", True)),
        )
        raw_water = add_waterway_corridors(
            raw_water,
            water_lines,
            min_latitude=min_latitude,
            min_longitude=min_longitude,
            step=regional_step,
            rows=rows,
            columns=columns,
            width_meters=float(region.get("linearWaterwayWidthMeters", 0)),
        )
        safe_water = erode_mask(
            raw_water,
            min_latitude=min_latitude,
            step=regional_step,
            columns=columns,
            clearance_meters=clearance_meters,
        )
        direction_layers = [
            gateway_directions(
                safe_water,
                min_latitude=min_latitude,
                min_longitude=min_longitude,
                step=regional_step,
                rows=rows,
                columns=columns,
                gateway=gateway,
            )
            for gateway in gateways
        ]
        write_grid(
            args.output / f"{name}.mrkgrid",
            safe_water,
            {
                "name": name,
                "kind": region.get("kind", "constrained"),
                "minLatitude": min_latitude,
                "minLongitude": min_longitude,
                "step": regional_step,
                "rows": rows,
                "columns": columns,
                "clearanceMeters": clearance_meters,
                "gateways": [
                    {"latitude": gateway[0], "longitude": gateway[1]}
                    for gateway in gateways
                ],
                "hasGatewayDirections": True,
                "reachableCellsByGateway": [
                    sum(direction != 15 for direction in directions)
                    for directions in direction_layers
                ],
                "sourceSHA256": sha256(source),
            },
            direction_layers,
        )


if __name__ == "__main__":
    main()
