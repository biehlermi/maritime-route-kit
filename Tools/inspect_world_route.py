#!/usr/bin/env python3
"""Validate and report the composition of a `.mrkroute` resource."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import zlib


HEADER = struct.Struct("<8sIIIII")
TILE_ENTRY = struct.Struct("<HHHHHBBQIII")
NODE_ENTRY = struct.Struct("<HIH")
EDGE_ENTRY = struct.Struct("<IIiH2x")


def inflate(payload: bytes) -> bytes:
    return zlib.decompress(payload, wbits=-zlib.MAX_WBITS)


def inspect(path: Path, maximum_size_mib: float) -> dict[str, object]:
    data = path.read_bytes()
    maximum_bytes = round(maximum_size_mib * 1024 * 1024)
    if len(data) > maximum_bytes:
        raise ValueError(f"{path} is {len(data)} bytes; limit is {maximum_bytes}")
    if len(data) < HEADER.size:
        raise ValueError("Truncated resource header")
    magic, metadata_length, tile_count, graph_length, graph_raw_length, entry_size = (
        HEADER.unpack_from(data)
    )
    if magic != b"MRKROUTE" or entry_size != TILE_ENTRY.size:
        raise ValueError("Unsupported resource header")
    metadata_start = HEADER.size
    metadata_end = metadata_start + metadata_length
    directory_start = metadata_end
    directory_end = directory_start + tile_count * entry_size
    graph_start = directory_end
    graph_end = graph_start + graph_length
    if graph_end > len(data):
        raise ValueError("Truncated resource sections")
    metadata = json.loads(data[metadata_start:metadata_end])
    if metadata.get("schemaVersion") != 1 or metadata.get("tileSize") != 128:
        raise ValueError("Unsupported resource metadata")

    seen_tiles: set[tuple[int, int, int]] = set()
    tile_raw_bytes = 0
    tile_compressed_bytes = 0
    tile_kinds = {"land": 0, "water": 0, "mixed": 0}
    payload_end = 0
    for index in range(tile_count):
        entry = TILE_ENTRY.unpack_from(data, directory_start + index * entry_size)
        grid, tile_row, tile_column, rows, columns, kind, reserved, offset, length, raw, crc = entry
        key = (grid, tile_row, tile_column)
        if key in seen_tiles:
            raise ValueError(f"Duplicate tile {key}")
        seen_tiles.add(key)
        if reserved or not (0 <= grid < len(metadata["grids"])) or not (0 < rows <= 128):
            raise ValueError(f"Invalid tile directory entry {index}")
        if not (0 < columns <= 128) or kind not in (0, 1, 2):
            raise ValueError(f"Invalid tile dimensions or kind at {index}")
        if graph_end + offset + length > len(data):
            raise ValueError(f"Tile payload outside resource at {index}")
        tile_raw_bytes += raw
        tile_compressed_bytes += length
        tile_kinds[("land", "water", "mixed")[kind]] += 1
        payload_end = max(payload_end, offset + length)
        if kind == 2:
            decoded = inflate(data[graph_end + offset : graph_end + offset + length])
            if len(decoded) != raw or zlib.crc32(decoded) & 0xFFFF_FFFF != crc:
                raise ValueError(f"Invalid compressed tile {index}")
        elif length or crc:
            raise ValueError(f"Uniform tile {index} unexpectedly has a payload")
    if graph_end + payload_end != len(data):
        raise ValueError("Unindexed bytes at end of resource")

    graph = inflate(data[graph_start:graph_end])
    if len(graph) != graph_raw_length or len(graph) < 8:
        raise ValueError("Invalid compressed graph")
    node_count, edge_count = struct.unpack_from("<II", graph)
    nodes_start = 8
    offsets_start = nodes_start + node_count * NODE_ENTRY.size
    edges_start = offsets_start + (node_count + 1) * 4
    if edges_start + edge_count * EDGE_ENTRY.size != len(graph):
        raise ValueError("Graph section lengths do not agree")
    offsets = struct.unpack_from(f"<{node_count + 1}I", graph, offsets_start)
    if offsets[0] != 0 or offsets[-1] != edge_count or any(
        first > second for first, second in zip(offsets, offsets[1:])
    ):
        raise ValueError("Invalid CSR offsets")
    node_by_cell: dict[tuple[int, int], int] = {}
    for index in range(node_count):
        grid, linear, reserved = NODE_ENTRY.unpack_from(graph, nodes_start + index * 8)
        if reserved or grid >= len(metadata["grids"]):
            raise ValueError(f"Invalid graph node {index}")
        grid_metadata = metadata["grids"][grid]
        if linear >= grid_metadata["rows"] * grid_metadata["columns"]:
            raise ValueError(f"Graph node {index} is outside its grid")
        node_by_cell[(grid, linear)] = index
    for index in range(edge_count):
        target, cost, context, passage = EDGE_ENTRY.unpack_from(
            graph, edges_start + index * EDGE_ENTRY.size
        )
        if target >= node_count or cost == 0:
            raise ValueError(f"Invalid graph edge {index}")
        if context >= tile_count or passage not in range(len(metadata["passages"])) and passage != 0xFFFF:
            raise ValueError(f"Invalid graph edge metadata {index}")

    gateway_nodes: list[int] = []
    for grid_index, grid in enumerate(metadata["grids"]):
        gateways = grid.get("gateways")
        if not gateways and grid.get("gatewayLatitude") is not None:
            gateways = [
                {
                    "latitude": grid["gatewayLatitude"],
                    "longitude": grid["gatewayLongitude"],
                }
            ]
        for gateway in gateways or []:
            row = int((gateway["latitude"] - grid["minLatitude"]) // grid["step"])
            column = int((gateway["longitude"] - grid["minLongitude"]) // grid["step"])
            node = node_by_cell.get((grid_index, row * grid["columns"] + column))
            if node is None:
                raise ValueError(f"Grid {grid_index} gateway is not a graph node")
            gateway_nodes.append(node)
    if not gateway_nodes:
        raise ValueError("Resource declares no regional gateways")
    visited = {gateway_nodes[0]}
    frontier = [gateway_nodes[0]]
    while frontier:
        node = frontier.pop()
        for edge_index in range(offsets[node], offsets[node + 1]):
            target = EDGE_ENTRY.unpack_from(graph, edges_start + edge_index * EDGE_ENTRY.size)[0]
            if target not in visited:
                visited.add(target)
                frontier.append(target)
    if any(node not in visited for node in gateway_nodes):
        raise ValueError("Declared gateways do not belong to one routed component")

    return {
        "path": str(path),
        "bytes": len(data),
        "maximumBytes": maximum_bytes,
        "sha256": hashlib.sha256(data).hexdigest(),
        "metadataBytes": metadata_length,
        "tileDirectoryBytes": tile_count * entry_size,
        "tilePayloadBytes": tile_compressed_bytes,
        "tileRawBytes": tile_raw_bytes,
        "tileKinds": tile_kinds,
        "graphCompressedBytes": graph_length,
        "graphRawBytes": graph_raw_length,
        "graphNodes": node_count,
        "graphDirectedEdges": edge_count,
        "gatewayNodes": len(gateway_nodes),
        "gatewayComponentNodes": len(visited),
        "grids": len(metadata["grids"]),
        "passages": metadata["passages"],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("resource", type=Path)
    parser.add_argument("--maximum-size-mib", type=float, default=25)
    arguments = parser.parse_args()
    print(json.dumps(inspect(arguments.resource, arguments.maximum_size_mib), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
