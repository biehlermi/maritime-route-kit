#!/usr/bin/env python3
"""Build MaritimeRouteKit's compact offline water grids.

The script intentionally uses only Python's standard library. It consumes the
version-pinned Natural Earth ocean shapefile and date-pinned Overpass JSON
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


def overpass_geometry(path: Path) -> tuple[list[list[tuple[float, float]]], list[list[tuple[float, float]]]]:
    payload = json.loads(path.read_text())
    coastlines: list[list[tuple[float, float]]] = []
    water_rings: list[list[tuple[float, float]]] = []

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
    return coastlines, water_rings


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

    coastline_water: list[int] = []
    global_columns = round(360 / global_step)
    for row, crossings in enumerate(intersections):
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
    directions: bytearray | None = None,
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
        if directions is not None:
            packed = bytearray((len(directions) + 1) // 2)
            for index, direction in enumerate(directions):
                packed[index // 2] |= direction << (4 * (index % 2))
            handle.write(packed)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--natural-earth-shp", type=Path, required=True)
    parser.add_argument("--elbe-json", type=Path, required=True)
    parser.add_argument("--geiranger-json", type=Path, required=True)
    parser.add_argument("--stockholm-json", type=Path, required=True)
    parser.add_argument("--bergen-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    global_step = 0.025
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

    patches = [
        (
            "bergen",
            args.bergen_json,
            (59.95, 4.70, 60.60, 5.55),
            (60.25, 4.74),
        ),
        (
            "elbe",
            args.elbe_json,
            (53.25, 8.35, 54.25, 10.25),
            (53.999, 8.415),
        ),
        (
            "geirangerfjord",
            args.geiranger_json,
            (61.85, 5.65, 62.65, 7.55),
            (62.45, 5.72),
        ),
        (
            "stockholm",
            args.stockholm_json,
            (58.75, 17.45, 59.85, 19.55),
            (59.10, 19.48),
        ),
    ]
    regional_step = 0.0005
    for name, source, bounds, gateway in patches:
        min_latitude, min_longitude, max_latitude, max_longitude = bounds
        rows = math.ceil((max_latitude - min_latitude) / regional_step)
        columns = math.ceil((max_longitude - min_longitude) / regional_step)
        coastlines, water_rings = overpass_geometry(source)
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
        )
        safe_water = erode_mask(
            raw_water,
            min_latitude=min_latitude,
            step=regional_step,
            columns=columns,
            clearance_meters=25,
        )
        directions = gateway_directions(
            safe_water,
            min_latitude=min_latitude,
            min_longitude=min_longitude,
            step=regional_step,
            rows=rows,
            columns=columns,
            gateway=gateway,
        )
        write_grid(
            args.output / f"{name}.mrkgrid",
            safe_water,
            {
                "name": name,
                "kind": "constrained",
                "minLatitude": min_latitude,
                "minLongitude": min_longitude,
                "step": regional_step,
                "rows": rows,
                "columns": columns,
                "clearanceMeters": 25,
                "gatewayLatitude": gateway[0],
                "gatewayLongitude": gateway[1],
                "hasGatewayDirections": True,
                "reachableCells": sum(direction != 15 for direction in directions),
                "sourceSHA256": sha256(source),
            },
            directions,
        )


if __name__ == "__main__":
    main()
