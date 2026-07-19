import Compression
import Foundation

/// Reader for the single deterministic `world.mrkroute` container.
///
/// The graph is decompressed once and retained as packed bytes. Water tiles are
/// decompressed independently and kept in a bounded cache, so normal routes do
/// not materialize the worldwide raster in memory.
final class WorldRouteResource: @unchecked Sendable {
  struct Metadata: Decodable, Sendable {
    struct Graph: Decodable, Sendable {
      let nodes: Int
      let directedEdges: Int
    }

    let schemaVersion: Int
    let tileSize: Int
    let compression: String
    let grids: [WaterGridMetadata]
    let passages: [String]
    let graph: Graph
  }

  struct TileEntry: Sendable {
    let gridIndex: Int
    let tileRow: Int
    let tileColumn: Int
    let rows: Int
    let columns: Int
    let kind: UInt8
    let payloadOffset: Int
    let compressedLength: Int
    let rawLength: Int
    let checksum: UInt32
  }

  struct GraphNode: Sendable {
    let gridIndex: Int
    let linearCell: Int
  }

  struct GraphEdge: Sendable {
    let target: Int
    let cost: Double
    let tileContext: Int?
    let passageIndex: Int?
  }

  private final class TileBox: NSObject {
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
  }

  let metadata: Metadata
  let tiles: [TileEntry]
  let graphNodeCount: Int
  let graphEdgeCount: Int
  let nodesByTile: [Int: [Int]]
  let installedByteCount: Int

  private let container: Data
  private let tilePayloadStart: Int
  private let graph: Data
  private let graphNodesStart: Int
  private let graphOffsetsStart: Int
  private let graphEdgesStart: Int
  private let tileIndexByKey: [UInt64: Int]
  private let tileCache = NSCache<NSNumber, TileBox>()

  convenience init() throws {
    guard let url = Bundle.module.url(forResource: "world", withExtension: "mrkroute") else {
      throw CocoaError(.fileNoSuchFile)
    }
    try self.init(url: url)
  }

  init(url: URL) throws {
    let container = try Data(contentsOf: url, options: .mappedIfSafe)
    guard container.count >= 28, container.count <= 25 * 1_024 * 1_024,
      container.prefix(8) == Data("MRKROUTE".utf8)
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let metadataLength = try Self.int32(container, at: 8)
    let tileCount = try Self.int32(container, at: 12)
    let graphCompressedLength = try Self.int32(container, at: 16)
    let graphRawLength = try Self.int32(container, at: 20)
    let tileEntrySize = try Self.int32(container, at: 24)
    guard metadataLength >= 0, tileCount >= 0, graphCompressedLength >= 0,
      graphRawLength >= 8, tileEntrySize == 32
    else { throw CocoaError(.fileReadCorruptFile) }

    let metadataStart = 28
    let metadataEnd = metadataStart + metadataLength
    let directoryStart = metadataEnd
    let directoryEnd = directoryStart + tileCount * tileEntrySize
    let graphStart = directoryEnd
    let graphEnd = graphStart + graphCompressedLength
    guard metadataEnd <= container.count, directoryEnd <= container.count,
      graphEnd <= container.count
    else { throw CocoaError(.fileReadCorruptFile) }

    let metadata = try JSONDecoder().decode(
      Metadata.self, from: container[metadataStart..<metadataEnd])
    guard metadata.schemaVersion == 1, metadata.tileSize == 128,
      metadata.compression == "zlib",
      metadata.grids.count(where: { $0.kind == "global" }) == 1
    else { throw CocoaError(.fileReadUnsupportedScheme) }

    var tiles: [TileEntry] = []
    tiles.reserveCapacity(tileCount)
    var tileIndexByKey: [UInt64: Int] = [:]
    tileIndexByKey.reserveCapacity(tileCount)
    for index in 0..<tileCount {
      let offset = directoryStart + index * tileEntrySize
      let entry = TileEntry(
        gridIndex: try Self.int16(container, at: offset),
        tileRow: try Self.int16(container, at: offset + 2),
        tileColumn: try Self.int16(container, at: offset + 4),
        rows: try Self.int16(container, at: offset + 6),
        columns: try Self.int16(container, at: offset + 8),
        kind: container[offset + 10],
        payloadOffset: try Self.int64(container, at: offset + 12),
        compressedLength: try Self.int32(container, at: offset + 20),
        rawLength: try Self.int32(container, at: offset + 24),
        checksum: try Self.uint32(container, at: offset + 28)
      )
      guard metadata.grids.indices.contains(entry.gridIndex), entry.rows > 0,
        entry.columns > 0, entry.rows <= metadata.tileSize,
        entry.columns <= metadata.tileSize, (0...2).contains(entry.kind),
        entry.payloadOffset >= 0, entry.compressedLength >= 0, entry.rawLength >= 0,
        graphEnd + entry.payloadOffset + entry.compressedLength <= container.count
      else { throw CocoaError(.fileReadCorruptFile) }
      guard
        tileIndexByKey.updateValue(
          index, forKey: Self.tileKey(entry.gridIndex, entry.tileRow, entry.tileColumn)) == nil
      else { throw CocoaError(.fileReadCorruptFile) }
      tiles.append(entry)
    }

    let compressedGraph = container[graphStart..<graphEnd]
    let graph = try Self.decompress(compressedGraph, expectedLength: graphRawLength)
    let graphNodeCount = try Self.int32(graph, at: 0)
    let graphEdgeCount = try Self.int32(graph, at: 4)
    let graphNodesStart = 8
    let graphOffsetsStart = graphNodesStart + graphNodeCount * 8
    let graphEdgesStart = graphOffsetsStart + (graphNodeCount + 1) * 4
    guard graphNodeCount == metadata.graph.nodes,
      graphEdgeCount == metadata.graph.directedEdges,
      graphEdgesStart + graphEdgeCount * 16 == graph.count
    else { throw CocoaError(.fileReadCorruptFile) }

    var nodesByTile: [Int: [Int]] = [:]
    nodesByTile.reserveCapacity(min(tileCount, graphNodeCount))
    for nodeIndex in 0..<graphNodeCount {
      let nodeOffset = graphNodesStart + nodeIndex * 8
      let gridIndex = try Self.int16(graph, at: nodeOffset)
      let linearCell = try Self.int32(graph, at: nodeOffset + 2)
      guard metadata.grids.indices.contains(gridIndex),
        linearCell >= 0,
        linearCell < metadata.grids[gridIndex].rows * metadata.grids[gridIndex].columns
      else { throw CocoaError(.fileReadCorruptFile) }
      let grid = metadata.grids[gridIndex]
      let row = linearCell / grid.columns
      let column = linearCell % grid.columns
      guard
        let tileIndex = tileIndexByKey[
          Self.tileKey(gridIndex, row / metadata.tileSize, column / metadata.tileSize)]
      else { throw CocoaError(.fileReadCorruptFile) }
      nodesByTile[tileIndex, default: []].append(nodeIndex)
    }
    guard try Self.int32(graph, at: graphOffsetsStart) == 0,
      try Self.int32(graph, at: graphOffsetsStart + graphNodeCount * 4) == graphEdgeCount
    else { throw CocoaError(.fileReadCorruptFile) }

    self.container = container
    self.metadata = metadata
    self.tiles = tiles
    self.tilePayloadStart = graphEnd
    self.graph = graph
    self.graphNodeCount = graphNodeCount
    self.graphEdgeCount = graphEdgeCount
    self.installedByteCount = container.count
    self.graphNodesStart = graphNodesStart
    self.graphOffsetsStart = graphOffsetsStart
    self.graphEdgesStart = graphEdgesStart
    self.tileIndexByKey = tileIndexByKey
    self.nodesByTile = nodesByTile
    tileCache.totalCostLimit = 32 * 1_024 * 1_024
  }

  func tileIndex(gridIndex: Int, row: Int, column: Int) -> Int? {
    guard row >= 0, column >= 0 else { return nil }
    return tileIndexByKey[
      Self.tileKey(gridIndex, row / metadata.tileSize, column / metadata.tileSize)]
  }

  func isNavigable(gridIndex: Int, row: Int, column: Int) -> Bool {
    guard metadata.grids.indices.contains(gridIndex) else { return false }
    let grid = metadata.grids[gridIndex]
    guard (0..<grid.rows).contains(row), (0..<grid.columns).contains(column),
      let tileIndex = tileIndex(gridIndex: gridIndex, row: row, column: column)
    else { return false }
    let tile = tiles[tileIndex]
    switch tile.kind {
    case 0: return false
    case 1: return true
    case 2:
      guard let bytes = try? tileBytes(at: tileIndex) else { return false }
      let localRow = row - tile.tileRow * metadata.tileSize
      let localColumn = column - tile.tileColumn * metadata.tileSize
      let rowBytes = (tile.columns + 7) / 8
      let byte = bytes[localRow * rowBytes + localColumn / 8]
      return byte & UInt8(1 << (localColumn % 8)) != 0
    default: return false
    }
  }

  func node(at index: Int) -> GraphNode {
    precondition((0..<graphNodeCount).contains(index))
    let offset = graphNodesStart + index * 8
    return GraphNode(
      gridIndex: Self.uncheckedUInt16(graph, at: offset),
      linearCell: Self.uncheckedUInt32(graph, at: offset + 2))
  }

  func outgoingEdgeRange(for node: Int) -> Range<Int> {
    precondition((0..<graphNodeCount).contains(node))
    let start = Self.uncheckedUInt32(graph, at: graphOffsetsStart + node * 4)
    let end = Self.uncheckedUInt32(graph, at: graphOffsetsStart + (node + 1) * 4)
    return start..<end
  }

  func edge(at index: Int) -> GraphEdge {
    precondition((0..<graphEdgeCount).contains(index))
    let offset = graphEdgesStart + index * 16
    let context = Self.uncheckedInt32(graph, at: offset + 8)
    let passage = Self.uncheckedUInt16(graph, at: offset + 12)
    return GraphEdge(
      target: Self.uncheckedUInt32(graph, at: offset),
      cost: Double(Self.uncheckedUInt32(graph, at: offset + 4)),
      tileContext: context < 0 ? nil : context,
      passageIndex: passage == 0xFFFF ? nil : passage
    )
  }

  private func tileBytes(at index: Int) throws -> Data {
    if let cached = tileCache.object(forKey: NSNumber(value: index)) { return cached.bytes }
    let entry = tiles[index]
    guard entry.kind == 2 else { return Data() }
    let start = tilePayloadStart + entry.payloadOffset
    let end = start + entry.compressedLength
    let bytes = try Self.decompress(container[start..<end], expectedLength: entry.rawLength)
    guard Self.crc32(bytes) == entry.checksum else { throw CocoaError(.fileReadCorruptFile) }
    tileCache.setObject(TileBox(bytes), forKey: NSNumber(value: index), cost: bytes.count)
    return bytes
  }

  private static func tileKey(_ gridIndex: Int, _ tileRow: Int, _ tileColumn: Int) -> UInt64 {
    (UInt64(gridIndex) << 48) | (UInt64(tileRow) << 24) | UInt64(tileColumn)
  }

  private static func decompress(_ source: Data.SubSequence, expectedLength: Int) throws -> Data {
    var output = Data(count: expectedLength)
    let decoded = output.withUnsafeMutableBytes { destination in
      source.withUnsafeBytes { input in
        compression_decode_buffer(
          destination.bindMemory(to: UInt8.self).baseAddress!, expectedLength,
          input.bindMemory(to: UInt8.self).baseAddress!, source.count,
          nil, COMPRESSION_ZLIB)
      }
    }
    guard decoded == expectedLength else { throw CocoaError(.fileReadCorruptFile) }
    return output
  }

  private static func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
      crc ^= UInt32(byte)
      for _ in 0..<8 {
        crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
      }
    }
    return ~crc
  }

  private static func int16(_ data: Data, at offset: Int) throws -> Int {
    guard offset >= 0, offset + 2 <= data.count else { throw CocoaError(.fileReadCorruptFile) }
    return uncheckedUInt16(data, at: offset)
  }

  private static func int32(_ data: Data, at offset: Int) throws -> Int {
    guard offset >= 0, offset + 4 <= data.count else { throw CocoaError(.fileReadCorruptFile) }
    return uncheckedUInt32(data, at: offset)
  }

  private static func uint32(_ data: Data, at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else { throw CocoaError(.fileReadCorruptFile) }
    return UInt32(uncheckedUInt32(data, at: offset))
  }

  private static func int64(_ data: Data, at offset: Int) throws -> Int {
    guard offset >= 0, offset + 8 <= data.count else { throw CocoaError(.fileReadCorruptFile) }
    var value: UInt64 = 0
    for index in 0..<8 { value |= UInt64(data[offset + index]) << UInt64(index * 8) }
    guard value <= UInt64(Int.max) else { throw CocoaError(.fileReadCorruptFile) }
    return Int(value)
  }

  private static func uncheckedUInt16(_ data: Data, at offset: Int) -> Int {
    Int(data[offset]) | (Int(data[offset + 1]) << 8)
  }

  private static func uncheckedUInt32(_ data: Data, at offset: Int) -> Int {
    Int(data[offset]) | (Int(data[offset + 1]) << 8) | (Int(data[offset + 2]) << 16)
      | (Int(data[offset + 3]) << 24)
  }

  private static func uncheckedInt32(_ data: Data, at offset: Int) -> Int {
    let value = UInt32(uncheckedUInt32(data, at: offset))
    return Int(Int32(bitPattern: value))
  }
}
