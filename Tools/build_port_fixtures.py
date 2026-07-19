#!/usr/bin/env python3
"""Create deterministic, globally distributed WPI port coverage fixtures."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
from collections import defaultdict, deque

from build_world_route import Cell, read_grid


def source_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def represented_within_25_kilometers(grid, latitude: float, longitude: float) -> bool:
    cell = grid.cell(latitude, longitude)
    if cell is None:
        return False
    if grid.navigable(cell):
        return True
    latitude_meters = grid.step * 111_195
    longitude_meters = max(1, latitude_meters * abs(math.cos(math.radians(latitude))))
    row_radius = math.ceil(25_000 / latitude_meters)
    column_radius = math.ceil(25_000 / longitude_meters)
    for row_offset in range(-row_radius, row_radius + 1):
        for column_offset in range(-column_radius, column_radius + 1):
            candidate = Cell(cell.row + row_offset, (cell.column + column_offset) % grid.columns)
            if not grid.navigable(candidate):
                continue
            candidate_latitude, candidate_longitude = grid.coordinate(candidate)
            north = (candidate_latitude - latitude) * 111_195
            east = (candidate_longitude - longitude) * longitude_meters / grid.step
            if math.hypot(north, east) <= 25_000:
                return True
    return False


def build(source: Path, global_grid_path: Path, output: Path, count: int) -> None:
    global_grid = read_grid(global_grid_path)
    by_country: dict[str, list[dict[str, object]]] = defaultdict(list)
    with source.open(encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            try:
                latitude = float(row["Latitude"])
                longitude = float(row["Longitude"])
                identifier = str(round(float(row["World Port Index Number"])))
            except (KeyError, TypeError, ValueError):
                continue
            if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
                continue
            if not represented_within_25_kilometers(global_grid, latitude, longitude):
                continue
            country = row.get("Country Code", "").strip() or "ZZ"
            size_rank = {"Large": 0, "Medium": 1, "Small": 2, "Very Small": 3}.get(
                row.get("Harbor Size", ""), 4
            )
            by_country[country].append(
                {
                    "id": f"wpi-{identifier}",
                    "name": row.get("Main Port Name", "").strip(),
                    "country": country,
                    "waterBody": row.get("World Water Body", "").strip(),
                    "latitude": latitude,
                    "longitude": longitude,
                    "_rank": size_rank,
                }
            )

    countries: dict[str, deque[dict[str, object]]] = {}
    for country, fixtures in by_country.items():
        fixtures.sort(key=lambda fixture: (fixture["_rank"], fixture["name"], fixture["id"]))
        countries[country] = deque(fixtures)
    selected: list[dict[str, object]] = []
    country_names = sorted(countries)
    while len(selected) < count:
        made_progress = False
        for country in country_names:
            if countries[country]:
                fixture = countries[country].popleft()
                fixture.pop("_rank")
                selected.append(fixture)
                made_progress = True
                if len(selected) == count:
                    break
        if not made_progress:
            break
    if len(selected) != count:
        raise ValueError(f"Only {len(selected)} represented WPI ports were available")

    payload = {
        "schemaVersion": 1,
        "source": "NGA World Port Index UpdatedPub150.csv",
        "sourceSHA256": source_hash(source),
        "selection": "country-round-robin, harbor-size then name; globally represented within 25 km",
        "ports": selected,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"output": str(output), "ports": len(selected)}, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--global-grid", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--count", type=int, default=600)
    arguments = parser.parse_args()
    build(arguments.source, arguments.global_grid, arguments.output, arguments.count)


if __name__ == "__main__":
    main()
