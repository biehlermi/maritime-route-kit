#!/usr/bin/env python3
"""Build MaritimeRouteKit's single compressed worldwide routing resource.

The input ``.mrkgrid`` files are deterministic intermediate masks produced by
``build_water_data.py``. They are not shipped by the Swift package. This tool
tiles and compresses their water bits, derives a hierarchical portal graph,
and writes the one ``world.mrkroute`` file consumed at runtime.

Only Python's standard library is required. Output ordering and compression
settings are fixed so identical inputs produce byte-identical output.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import heapq
import json
import math
from pathlib import Path
import struct
from typing import Iterable, Sequence
import zlib


GRID_MAGIC = b"MRKGRID1"
ROUTE_MAGIC = b"MRKROUTE"
TILE_SIZE = 128
PORTAL_SPACING = 32
EARTH_RADIUS_METERS = 6_371_008.8
DIRECT_EDGE_CONTEXT = -1
NO_PASSAGE = 0xFFFF
MAXIMUM_RESOURCE_BYTES = 25 * 1024 * 1024
HEADER = struct.Struct("<8sIIIII")
TILE_ENTRY = struct.Struct("<HHHHHBBQIII")
NODE_ENTRY = struct.Struct("<HIH")
EDGE_ENTRY = struct.Struct("<IIiH2x")


def compress_block(raw: bytes) -> bytes:
    """Encode the deterministic raw DEFLATE stream used by Compression.framework."""
    compressor = zlib.compressobj(level=9, method=zlib.DEFLATED, wbits=-zlib.MAX_WBITS)
    return compressor.compress(raw) + compressor.flush()


@dataclass(frozen=True)
class Cell:
    row: int
    column: int


@dataclass
class Grid:
    name: str
    metadata: dict[str, object]
    rows_mask: list[int]
    source_path: Path

    @property
    def rows(self) -> int:
        return int(self.metadata["rows"])

    @property
    def columns(self) -> int:
        return int(self.metadata["columns"])

    @property
    def step(self) -> float:
        return float(self.metadata["step"])

    @property
    def is_global(self) -> bool:
        return self.metadata["kind"] == "global"

    def navigable(self, cell: Cell) -> bool:
        if not 0 <= cell.row < self.rows:
            return False
        column = cell.column
        if self.is_global:
            column %= self.columns
        if not 0 <= column < self.columns:
            return False
        return bool(self.rows_mask[cell.row] & (1 << column))

    def coordinate(self, cell: Cell) -> tuple[float, float]:
        latitude = float(self.metadata["minLatitude"]) + (cell.row + 0.5) * self.step
        longitude = float(self.metadata["minLongitude"]) + (cell.column + 0.5) * self.step
        while longitude > 180:
            longitude -= 360
        while longitude < -180:
            longitude += 360
        return latitude, longitude

    def cell(self, latitude: float, longitude: float) -> Cell | None:
        row = math.floor((latitude - float(self.metadata["minLatitude"])) / self.step)
        column = math.floor((longitude - float(self.metadata["minLongitude"])) / self.step)
        if self.is_global:
            column %= self.columns
        cell = Cell(row, column)
        return cell if 0 <= row < self.rows and 0 <= column < self.columns else None

    def gateways(self) -> list[tuple[float, float]]:
        configured = self.metadata.get("gateways")
        if configured:
            return [
                (float(item["latitude"]), float(item["longitude"]))
                for item in configured
            ]
        latitude = self.metadata.get("gatewayLatitude")
        longitude = self.metadata.get("gatewayLongitude")
        return [] if latitude is None or longitude is None else [(float(latitude), float(longitude))]


@dataclass(frozen=True)
class Tile:
    grid_index: int
    tile_row: int
    tile_column: int
    rows: int
    columns: int
    kind: int
    payload: bytes
    raw_length: int
    checksum: int


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_grid(path: Path) -> Grid:
    data = path.read_bytes()
    if len(data) < 12 or data[:8] != GRID_MAGIC:
        raise ValueError(f"Invalid MRK grid: {path}")
    metadata_length = struct.unpack_from("<I", data, 8)[0]
    metadata_end = 12 + metadata_length
    metadata = json.loads(data[12:metadata_end])
    rows = int(metadata["rows"])
    columns = int(metadata["columns"])
    row_bytes = (columns + 7) // 8
    water_end = metadata_end + rows * row_bytes
    if water_end > len(data):
        raise ValueError(f"Truncated MRK grid: {path}")
    rows_mask = [
        int.from_bytes(
            data[metadata_end + row * row_bytes : metadata_end + (row + 1) * row_bytes],
            "little",
        )
        for row in range(rows)
    ]
    configured_gateways = metadata.get("gateways") or []
    gateway_count = len(configured_gateways) or (
        1
        if metadata.get("gatewayLatitude") is not None
        and metadata.get("gatewayLongitude") is not None
        else 0
    )
    if metadata.get("hasGatewayDirections"):
        layer_bytes = (rows * columns + 1) // 2
        if gateway_count == 0 or water_end + gateway_count * layer_bytes != len(data):
            raise ValueError(f"Invalid gateway layers in {path}")
        layer_starts = [water_end + index * layer_bytes for index in range(gateway_count)]
        # Direction value 15 means that a water cell cannot reach that grid's
        # ocean transfer. Exclude such cells from the shipped tile altogether,
        # preventing placement on disconnected lakes or water polygons.
        for row in range(rows):
            reachable = 0
            first_linear = row * columns
            for column in range(columns):
                linear = first_linear + column
                for layer_start in layer_starts:
                    packed = data[layer_start + linear // 2]
                    direction = (packed >> (4 * (linear % 2))) & 0x0F
                    if direction != 15:
                        reachable |= 1 << column
                        break
            rows_mask[row] &= reachable
    return Grid(str(metadata["name"]), metadata, rows_mask, path)


def distance(first: tuple[float, float], second: tuple[float, float]) -> float:
    lat1, lon1 = first
    lat2, lon2 = second
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    delta_lat = math.radians(lat2 - lat1)
    delta_lon = lon2 - lon1
    if delta_lon > 180:
        delta_lon -= 360
    if delta_lon < -180:
        delta_lon += 360
    delta_lon = math.radians(delta_lon)
    value = (
        math.sin(delta_lat / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(delta_lon / 2) ** 2
    )
    return EARTH_RADIUS_METERS * 2 * math.atan2(math.sqrt(value), math.sqrt(max(0, 1 - value)))


def tile_bounds(grid: Grid, tile_row: int, tile_column: int) -> tuple[int, int, int, int]:
    first_row = tile_row * TILE_SIZE
    first_column = tile_column * TILE_SIZE
    return (
        first_row,
        min(grid.rows, first_row + TILE_SIZE),
        first_column,
        min(grid.columns, first_column + TILE_SIZE),
    )


def encode_tile(grid: Grid, grid_index: int, tile_row: int, tile_column: int) -> Tile:
    first_row, last_row, first_column, last_column = tile_bounds(grid, tile_row, tile_column)
    rows = last_row - first_row
    columns = last_column - first_column
    row_bytes = (columns + 7) // 8
    raw = bytearray(rows * row_bytes)
    water_count = 0
    for local_row in range(rows):
        source = grid.rows_mask[first_row + local_row] >> first_column
        for column in range(columns):
            if source & (1 << column):
                raw[local_row * row_bytes + column // 8] |= 1 << (column % 8)
                water_count += 1
    if water_count == 0:
        return Tile(grid_index, tile_row, tile_column, rows, columns, 0, b"", len(raw), 0)
    if water_count == rows * columns:
        return Tile(grid_index, tile_row, tile_column, rows, columns, 1, b"", len(raw), 0)
    payload = compress_block(bytes(raw))
    return Tile(
        grid_index,
        tile_row,
        tile_column,
        rows,
        columns,
        2,
        payload,
        len(raw),
        zlib.crc32(raw) & 0xFFFF_FFFF,
    )


def add_connector_transfer_corridors(grids: Sequence[Grid], global_grid_index: int) -> None:
    """Join sparse canal masks to nearby global water without filling their bounds.

    Connector extracts intentionally omit surrounding ocean polygons. For each
    gateway, find the shortest path through the proven global mask until it
    leaves the connector bounds, then paint only that narrow overlap into the
    detailed mask. This gives the runtime an authoritative resolution handoff
    while preserving detailed land immediately beside the approach.
    """

    global_grid = grids[global_grid_index]
    directions = [(-1, 0), (-1, 1), (0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1)]

    for grid in grids:
        if grid.metadata["kind"] != "connector":
            continue
        transfer_coordinates: list[dict[str, float]] = []

        def inside_global_cell(cell: Cell) -> bool:
            latitude, longitude = global_grid.coordinate(cell)
            return (
                float(grid.metadata["minLatitude"])
                <= latitude
                < float(grid.metadata["minLatitude"]) + grid.rows * grid.step
                and float(grid.metadata["minLongitude"])
                <= longitude
                < float(grid.metadata["minLongitude"]) + grid.columns * grid.step
            )

        def paint(latitude: float, longitude: float, width_meters: float) -> None:
            center = grid.cell(latitude, longitude)
            if center is None:
                return
            latitude_meters = grid.step * 111_195
            longitude_meters = max(
                1.0, latitude_meters * abs(math.cos(math.radians(latitude)))
            )
            half_width = width_meters / 2
            row_radius = max(1, math.ceil(half_width / latitude_meters))
            column_radius = max(1, math.ceil(half_width / longitude_meters))
            for row_offset in range(-row_radius, row_radius + 1):
                row = center.row + row_offset
                if not 0 <= row < grid.rows:
                    continue
                for column_offset in range(-column_radius, column_radius + 1):
                    column = center.column + column_offset
                    if not 0 <= column < grid.columns:
                        continue
                    if math.hypot(
                        row_offset * latitude_meters,
                        column_offset * longitude_meters,
                    ) <= half_width + math.hypot(latitude_meters, longitude_meters) / 2:
                        grid.rows_mask[row] |= 1 << column

        width_meters = 300.0
        for gateway in grid.gateways():
            start = global_grid.cell(*gateway)
            if start is None or not global_grid.navigable(start):
                raise ValueError(f"Connector gateway {gateway} is not global water")
            frontier = [start]
            parent: dict[Cell, Cell | None] = {start: None}
            goal: Cell | None = None
            for current in frontier:
                if not inside_global_cell(current):
                    goal = current
                    break
                if len(parent) > 4096:
                    break
                for row_offset, column_offset in directions:
                    candidate = Cell(current.row + row_offset, current.column + column_offset)
                    normalized = Cell(candidate.row, candidate.column % global_grid.columns)
                    if normalized in parent or not global_grid.navigable(normalized):
                        continue
                    if row_offset and column_offset and (
                        not global_grid.navigable(Cell(current.row + row_offset, current.column))
                        or not global_grid.navigable(Cell(current.row, current.column + column_offset))
                    ):
                        continue
                    parent[normalized] = current
                    frontier.append(normalized)
            if goal is None:
                raise ValueError(f"No global-water transfer corridor for {grid.name} {gateway}")
            cells: list[Cell] = []
            current: Cell | None = goal
            while current is not None:
                cells.append(current)
                current = parent[current]
            points = [global_grid.coordinate(cell) for cell in reversed(cells)]
            for first, second in zip(points, points[1:]):
                delta_latitude = (second[0] - first[0]) / grid.step
                delta_longitude = (second[1] - first[1]) / grid.step
                samples = max(1, math.ceil(max(abs(delta_latitude), abs(delta_longitude)) * 3))
                for sample in range(samples + 1):
                    fraction = sample / samples
                    paint(
                        first[0] + (second[0] - first[0]) * fraction,
                        first[1] + (second[1] - first[1]) * fraction,
                        width_meters,
                    )
            inside_points = [point for point in points if grid.cell(*point) is not None]
            if not inside_points:
                raise ValueError(f"Empty detailed transfer overlap for {grid.name} {gateway}")
            transfer_latitude, transfer_longitude = inside_points[-1]
            transfer_coordinates.append(
                {"latitude": transfer_latitude, "longitude": transfer_longitude}
            )
        grid.metadata["transferCorridorWidthMeters"] = width_meters
        grid.metadata["transferCoordinates"] = transfer_coordinates


def selected_portals(start: int, end: int) -> list[int]:
    """Return deterministic representatives for one navigable border run."""
    result: list[int] = []
    cursor = start
    while cursor <= end:
        chunk_end = min(end, cursor + PORTAL_SPACING - 1)
        result.append((cursor + chunk_end) // 2)
        cursor = chunk_end + 1
    return result


def contiguous_runs(values: Iterable[tuple[int, bool]]) -> Iterable[tuple[int, int]]:
    start: int | None = None
    previous = -2
    for index, enabled in values:
        if enabled:
            if start is None or index != previous + 1:
                if start is not None:
                    yield start, previous
                start = index
            previous = index
        elif start is not None:
            yield start, previous
            start = None
    if start is not None:
        yield start, previous


class GraphBuilder:
    def __init__(self, grids: Sequence[Grid], tile_indices: dict[tuple[int, int, int], int]):
        self.grids = grids
        self.tile_indices = tile_indices
        self.nodes: list[tuple[int, int]] = []
        self.node_by_cell: list[dict[int, int]] = [{} for _ in grids]
        self.nodes_by_tile: dict[tuple[int, int, int], set[int]] = {}
        self.edges: list[dict[int, tuple[int, int, int]]] = []
        self.gateway_nodes: list[list[int]] = [[] for _ in grids]
        passage_names = sorted(grid.name for grid in grids if grid.metadata["kind"] == "connector")
        self.passage_indices = {name: index for index, name in enumerate(passage_names)}

    def add_node(self, grid_index: int, cell: Cell) -> int:
        grid = self.grids[grid_index]
        column = cell.column % grid.columns if grid.is_global else cell.column
        linear = cell.row * grid.columns + column
        existing = self.node_by_cell[grid_index].get(linear)
        if existing is not None:
            return existing
        node = len(self.nodes)
        self.nodes.append((grid_index, linear))
        self.node_by_cell[grid_index][linear] = node
        self.edges.append({})
        key = (grid_index, cell.row // TILE_SIZE, column // TILE_SIZE)
        self.nodes_by_tile.setdefault(key, set()).add(node)
        return node

    def node_cell(self, node: int) -> Cell:
        grid_index, linear = self.nodes[node]
        return Cell(*divmod(linear, self.grids[grid_index].columns))

    def node_coordinate(self, node: int) -> tuple[float, float]:
        grid_index, _ = self.nodes[node]
        return self.grids[grid_index].coordinate(self.node_cell(node))

    def add_edge(
        self,
        first: int,
        second: int,
        cost: float,
        context: int = DIRECT_EDGE_CONTEXT,
        passage: int = NO_PASSAGE,
    ) -> None:
        rounded = max(0, min(0xFFFF_FFFF, round(cost)))
        current = self.edges[first].get(second)
        candidate = (rounded, context, passage)
        if current is None or candidate < current:
            self.edges[first][second] = candidate

    def add_bidirectional_edge(
        self,
        first: int,
        second: int,
        cost: float,
        context: int = DIRECT_EDGE_CONTEXT,
        passage: int = NO_PASSAGE,
    ) -> None:
        self.add_edge(first, second, cost, context, passage)
        self.add_edge(second, first, cost, context, passage)

    def add_boundary_portals(self) -> None:
        for grid_index, grid in enumerate(self.grids):
            tile_rows = math.ceil(grid.rows / TILE_SIZE)
            tile_columns = math.ceil(grid.columns / TILE_SIZE)
            for tile_column in range(1, tile_columns):
                right_column = tile_column * TILE_SIZE
                left_column = right_column - 1
                runs = contiguous_runs(
                    (row, grid.navigable(Cell(row, left_column)) and grid.navigable(Cell(row, right_column)))
                    for row in range(grid.rows)
                )
                for start, end in runs:
                    for row in selected_portals(start, end):
                        left = self.add_node(grid_index, Cell(row, left_column))
                        right = self.add_node(grid_index, Cell(row, right_column))
                        self.add_bidirectional_edge(
                            left, right, distance(self.node_coordinate(left), self.node_coordinate(right))
                        )
            for tile_row in range(1, tile_rows):
                lower_row = tile_row * TILE_SIZE
                upper_row = lower_row - 1
                runs = contiguous_runs(
                    (
                        column,
                        grid.navigable(Cell(upper_row, column))
                        and grid.navigable(Cell(lower_row, column)),
                    )
                    for column in range(grid.columns)
                )
                for start, end in runs:
                    for column in selected_portals(start, end):
                        upper = self.add_node(grid_index, Cell(upper_row, column))
                        lower = self.add_node(grid_index, Cell(lower_row, column))
                        self.add_bidirectional_edge(
                            upper, lower, distance(self.node_coordinate(upper), self.node_coordinate(lower))
                        )
            if grid.is_global:
                runs = contiguous_runs(
                    (
                        row,
                        grid.navigable(Cell(row, grid.columns - 1))
                        and grid.navigable(Cell(row, 0)),
                    )
                    for row in range(grid.rows)
                )
                for start, end in runs:
                    for row in selected_portals(start, end):
                        west = self.add_node(grid_index, Cell(row, grid.columns - 1))
                        east = self.add_node(grid_index, Cell(row, 0))
                        self.add_bidirectional_edge(
                            west, east, distance(self.node_coordinate(west), self.node_coordinate(east))
                        )

    def add_gateways_and_transfers(self, global_grid_index: int) -> None:
        global_grid = self.grids[global_grid_index]
        for grid_index, grid in enumerate(self.grids):
            for latitude, longitude in grid.gateways():
                cell = grid.cell(latitude, longitude)
                if cell is None or not grid.navigable(cell):
                    raise ValueError(f"Gateway {(latitude, longitude)} is not water in {grid.name}")
                regional_node = self.add_node(grid_index, cell)
                self.gateway_nodes[grid_index].append(regional_node)
            configured_transfers = grid.metadata.get("transferCoordinates")
            transfer_coordinates = (
                [
                    (float(item["latitude"]), float(item["longitude"]))
                    for item in configured_transfers
                ]
                if configured_transfers
                else grid.gateways()
            )
            for latitude, longitude in transfer_coordinates:
                cell = grid.cell(latitude, longitude)
                if cell is None or not grid.navigable(cell):
                    raise ValueError(f"Transfer {(latitude, longitude)} is not water in {grid.name}")
                regional_node = self.add_node(grid_index, cell)
                if grid_index == global_grid_index:
                    continue
                global_cell = global_grid.cell(latitude, longitude)
                if global_cell is None or not global_grid.navigable(global_cell):
                    raise ValueError(
                        f"Gateway {(latitude, longitude)} does not overlap global water for {grid.name}"
                    )
                global_node = self.add_node(global_grid_index, global_cell)
                self.add_bidirectional_edge(
                    regional_node,
                    global_node,
                    distance(self.node_coordinate(regional_node), self.node_coordinate(global_node)),
                )

    def tile_segment_is_navigable(
        self, grid: Grid, first: Cell, second: Cell, bounds: tuple[int, int, int, int]
    ) -> bool:
        first_row, last_row, first_column, last_column = bounds
        delta_row = second.row - first.row
        delta_column = second.column - first.column
        samples = max(1, max(abs(delta_row), abs(delta_column)) * 6)
        for index in range(samples + 1):
            fraction = index / samples
            row = math.floor(first.row + delta_row * fraction + 0.5)
            column = math.floor(first.column + delta_column * fraction + 0.5)
            if not (first_row <= row < last_row and first_column <= column < last_column):
                return False
            if not grid.navigable(Cell(row, column)):
                return False
        return True

    def tile_shortest_cost(
        self, grid: Grid, start: Cell, goal: Cell, bounds: tuple[int, int, int, int]
    ) -> float | None:
        first_row, last_row, first_column, last_column = bounds
        width = last_column - first_column
        start_index = (start.row - first_row) * width + start.column - first_column
        goal_index = (goal.row - first_row) * width + goal.column - first_column
        cell_count = (last_row - first_row) * width
        costs = [math.inf] * cell_count
        costs[start_index] = 0.0
        frontier = [(0.0, 0.0, start_index)]
        offsets = [(-1, 0), (-1, 1), (0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1)]
        latitude_meters = grid.step * 111_195
        while frontier:
            _, cost, index = heapq.heappop(frontier)
            if costs[index] != cost:
                continue
            if index == goal_index:
                return cost
            local_row, local_column = divmod(index, width)
            row = first_row + local_row
            column = first_column + local_column
            latitude = float(grid.metadata["minLatitude"]) + (row + 0.5) * grid.step
            longitude_meters = max(1.0, latitude_meters * abs(math.cos(math.radians(latitude))))
            for row_offset, column_offset in offsets:
                next_row = row + row_offset
                next_column = column + column_offset
                if not (
                    first_row <= next_row < last_row
                    and first_column <= next_column < last_column
                ):
                    continue
                next_cell = Cell(next_row, next_column)
                if not grid.navigable(next_cell):
                    continue
                if row_offset and column_offset and (
                    not grid.navigable(Cell(row + row_offset, column))
                    or not grid.navigable(Cell(row, column + column_offset))
                ):
                    continue
                next_index = (next_row - first_row) * width + next_column - first_column
                step = math.hypot(
                    row_offset * latitude_meters, column_offset * longitude_meters
                )
                next_cost = cost + step
                if next_cost >= costs[next_index]:
                    continue
                costs[next_index] = next_cost
                row_distance = goal.row - next_row
                column_distance = goal.column - next_column
                heuristic = math.hypot(
                    row_distance * latitude_meters,
                    column_distance * longitude_meters,
                )
                heapq.heappush(frontier, (next_cost + heuristic, next_cost, next_index))
        return None

    def tile_water_components(
        self, grid: Grid, bounds: tuple[int, int, int, int]
    ) -> list[int]:
        first_row, last_row, first_column, last_column = bounds
        width = last_column - first_column
        height = last_row - first_row
        labels = [-1] * (width * height)
        component = 0
        for local_row in range(height):
            for local_column in range(width):
                start_index = local_row * width + local_column
                if labels[start_index] != -1:
                    continue
                start = Cell(first_row + local_row, first_column + local_column)
                if not grid.navigable(start):
                    labels[start_index] = -2
                    continue
                labels[start_index] = component
                frontier = [start_index]
                while frontier:
                    index = frontier.pop()
                    row, column = divmod(index, width)
                    for row_offset, column_offset in ((-1, 0), (0, 1), (1, 0), (0, -1)):
                        next_row = row + row_offset
                        next_column = column + column_offset
                        if not (0 <= next_row < height and 0 <= next_column < width):
                            continue
                        next_index = next_row * width + next_column
                        if labels[next_index] != -1:
                            continue
                        next_cell = Cell(first_row + next_row, first_column + next_column)
                        if grid.navigable(next_cell):
                            labels[next_index] = component
                            frontier.append(next_index)
                        else:
                            labels[next_index] = -2
                component += 1
        return labels

    def add_intratile_edges(self) -> None:
        total = len(self.nodes_by_tile)
        for progress, key in enumerate(sorted(self.nodes_by_tile), start=1):
            grid_index, tile_row, tile_column = key
            grid = self.grids[grid_index]
            nodes = sorted(self.nodes_by_tile[key])
            if len(nodes) < 2:
                continue
            bounds = tile_bounds(grid, tile_row, tile_column)
            context = self.tile_indices[key]
            passage = self.passage_indices.get(grid.name, NO_PASSAGE)
            parent = list(range(len(nodes)))

            def find(index: int) -> int:
                while parent[index] != index:
                    parent[index] = parent[parent[index]]
                    index = parent[index]
                return index

            def union(first: int, second: int) -> None:
                first_root = find(first)
                second_root = find(second)
                if first_root != second_root:
                    parent[second_root] = first_root

            first_row, last_row, first_column, last_column = bounds
            tile_mask = (1 << (last_column - first_column)) - 1
            entirely_water = all(
                (grid.rows_mask[row] >> first_column) & tile_mask == tile_mask
                for row in range(first_row, last_row)
            )
            labels = None if entirely_water else self.tile_water_components(grid, bounds)
            width = last_column - first_column

            def water_component(node: int) -> int:
                if labels is None:
                    return 0
                cell = self.node_cell(node)
                local_index = (cell.row - first_row) * width + cell.column - first_column
                return labels[local_index]

            for first_index, first in enumerate(nodes[:-1]):
                first_cell = self.node_cell(first)
                for second_index, second in enumerate(nodes[first_index + 1 :], start=first_index + 1):
                    second_cell = self.node_cell(second)
                    if water_component(first) == water_component(second) and (
                        entirely_water
                        or self.tile_segment_is_navigable(grid, first_cell, second_cell, bounds)
                    ):
                        self.add_bidirectional_edge(
                            first,
                            second,
                            distance(self.node_coordinate(first), self.node_coordinate(second)),
                            DIRECT_EDGE_CONTEXT,
                            passage,
                        )
                        union(first_index, second_index)

            # Open-water portals are joined by direct visibility. Obstacle-shaped
            # coastal tiles only need a minimal set of reconstructable local links
            # to join portals belonging to the same real water component.
            if len({find(index) for index in range(len(nodes))}) == 1:
                if progress % 500 == 0 or progress == total:
                    print(f"Built portal edges for {progress}/{total} occupied tiles", flush=True)
                continue
            nodes_by_water_component: dict[int, list[int]] = {}
            for node_index, node in enumerate(nodes):
                nodes_by_water_component.setdefault(water_component(node), []).append(node_index)
            for component_nodes in nodes_by_water_component.values():
                while len({find(index) for index in component_nodes}) > 1:
                    candidates: list[tuple[float, int, int]] = []
                    for offset, first_index in enumerate(component_nodes[:-1]):
                        for second_index in component_nodes[offset + 1 :]:
                            if find(first_index) == find(second_index):
                                continue
                            candidates.append(
                                (
                                    distance(
                                        self.node_coordinate(nodes[first_index]),
                                        self.node_coordinate(nodes[second_index]),
                                    ),
                                    first_index,
                                    second_index,
                                )
                            )
                    if not candidates:
                        break
                    _, first_index, second_index = min(candidates)
                    cost = self.tile_shortest_cost(
                        grid,
                        self.node_cell(nodes[first_index]),
                        self.node_cell(nodes[second_index]),
                        bounds,
                    )
                    if cost is None:
                        raise ValueError(f"Inconsistent water component in {key}")
                    self.add_bidirectional_edge(
                        nodes[first_index], nodes[second_index], cost, context, passage
                    )
                    union(first_index, second_index)
            if progress % 500 == 0 or progress == total:
                print(f"Built portal edges for {progress}/{total} occupied tiles", flush=True)

    def validate_gateway_connectivity(self) -> None:
        """Assert that every declared gateway belongs to the routed ocean component."""
        gateways = sorted(node for nodes in self.gateway_nodes for node in nodes)
        if not gateways:
            raise ValueError("At least one regional gateway is required")
        visited = {gateways[0]}
        frontier = [gateways[0]]
        while frontier:
            node = frontier.pop()
            for target in self.edges[node]:
                if target not in visited:
                    visited.add(target)
                    frontier.append(target)
        unreachable = [node for node in gateways if node not in visited]
        if unreachable:
            descriptions = [
                {
                    "grid": self.grids[self.nodes[node][0]].name,
                    "coordinate": self.node_coordinate(node),
                }
                for node in unreachable
            ]
            raise ValueError(f"Gateway nodes are not in one routed component: {descriptions}")

    def encode(self) -> bytes:
        adjacency_offsets = [0]
        encoded_edges: list[tuple[int, int, int, int]] = []
        for outgoing in self.edges:
            for target in sorted(outgoing):
                cost, context, passage = outgoing[target]
                encoded_edges.append((target, cost, context, passage))
            adjacency_offsets.append(len(encoded_edges))
        result = bytearray(struct.pack("<II", len(self.nodes), len(encoded_edges)))
        for grid_index, linear in self.nodes:
            result.extend(NODE_ENTRY.pack(grid_index, linear, 0))
        result.extend(struct.pack(f"<{len(adjacency_offsets)}I", *adjacency_offsets))
        for edge in encoded_edges:
            result.extend(EDGE_ENTRY.pack(*edge))
        return bytes(result)


def sanitized_metadata(grid: Grid) -> dict[str, object]:
    result = {
        key: value
        for key, value in grid.metadata.items()
        if key
        not in {
            "hasGatewayDirections",
            "reachableCells",
            "reachableCellsByGateway",
        }
    }
    result["sourceGridSHA256"] = sha256(grid.source_path)
    return result


def build(grid_directory: Path, output: Path) -> None:
    paths = sorted(grid_directory.glob("*.mrkgrid"))
    if not paths:
        raise ValueError(f"No .mrkgrid inputs found in {grid_directory}")
    grids = [read_grid(path) for path in paths]
    grids.sort(key=lambda grid: (not grid.is_global, grid.name))
    global_indices = [index for index, grid in enumerate(grids) if grid.is_global]
    if len(global_indices) != 1:
        raise ValueError("Exactly one global grid is required")
    add_connector_transfer_corridors(grids, global_indices[0])

    tiles: list[Tile] = []
    tile_indices: dict[tuple[int, int, int], int] = {}
    for grid_index, grid in enumerate(grids):
        tile_rows = math.ceil(grid.rows / TILE_SIZE)
        tile_columns = math.ceil(grid.columns / TILE_SIZE)
        for tile_row in range(tile_rows):
            for tile_column in range(tile_columns):
                tile_indices[(grid_index, tile_row, tile_column)] = len(tiles)
                tiles.append(encode_tile(grid, grid_index, tile_row, tile_column))

    graph = GraphBuilder(grids, tile_indices)
    graph.add_boundary_portals()
    graph.add_gateways_and_transfers(global_indices[0])
    graph.add_intratile_edges()
    graph.validate_gateway_connectivity()
    graph_raw = graph.encode()
    graph_payload = compress_block(graph_raw)

    metadata = {
        "schemaVersion": 1,
        "tileSize": TILE_SIZE,
        "portalSpacing": PORTAL_SPACING,
        "compression": "zlib",
        "grids": [sanitized_metadata(grid) for grid in grids],
        "passages": sorted(graph.passage_indices, key=graph.passage_indices.get),
        "graph": {
            "nodes": len(graph.nodes),
            "directedEdges": sum(len(edges) for edges in graph.edges),
        },
    }
    encoded_metadata = json.dumps(metadata, sort_keys=True, separators=(",", ":")).encode()

    payload_offset = 0
    directory = bytearray()
    payloads = bytearray()
    for tile in tiles:
        directory.extend(
            TILE_ENTRY.pack(
                tile.grid_index,
                tile.tile_row,
                tile.tile_column,
                tile.rows,
                tile.columns,
                tile.kind,
                0,
                payload_offset,
                len(tile.payload),
                tile.raw_length,
                tile.checksum,
            )
        )
        payloads.extend(tile.payload)
        payload_offset += len(tile.payload)

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as handle:
        handle.write(
            HEADER.pack(
                ROUTE_MAGIC,
                len(encoded_metadata),
                len(tiles),
                len(graph_payload),
                len(graph_raw),
                TILE_ENTRY.size,
            )
        )
        handle.write(encoded_metadata)
        handle.write(directory)
        handle.write(graph_payload)
        handle.write(payloads)

    if output.stat().st_size > MAXIMUM_RESOURCE_BYTES:
        raise ValueError(
            f"{output} is {output.stat().st_size} bytes; "
            f"limit is {MAXIMUM_RESOURCE_BYTES} bytes"
        )

    print(
        json.dumps(
            {
                "output": str(output),
                "bytes": output.stat().st_size,
                "sha256": sha256(output),
                "grids": len(grids),
                "tiles": len(tiles),
                "graphNodes": len(graph.nodes),
                "graphDirectedEdges": sum(len(edges) for edges in graph.edges),
                "graphRawBytes": len(graph_raw),
                "graphCompressedBytes": len(graph_payload),
            },
            indent=2,
            sort_keys=True,
        )
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--grid-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    build(args.grid_directory, args.output)


if __name__ == "__main__":
    main()
