import Foundation
import CryptoKit
import os

/// A tessellated model, independent of where it came from — freshly parsed by
/// OpenCASCADE, or restored from the cache.
struct MeshGroup {
    var firstIndex: UInt32
    var indexCount: UInt32
    var rgba: (Float, Float, Float, Float)
}

struct MeshData {
    var positions: [Float]
    var normals: [Float]
    var indices: [UInt32]
    var groups: [MeshGroup]
    var bboxMin: SIMD3<Float>
    var bboxMax: SIMD3<Float>
    var info: String

    var vertexCount: Int { positions.count / 3 }
    var triangleCount: Int { indices.count / 3 }
}

extension MeshData {
    /// Copies out of the C struct so the OpenCASCADE allocation can be freed
    /// immediately rather than kept alive for the life of the preview.
    init(copying mesh: CADMesh) {
        let vertexFloats = Int(mesh.vertexCount) * 3
        positions = Array(UnsafeBufferPointer(start: mesh.positions, count: vertexFloats))
        normals = Array(UnsafeBufferPointer(start: mesh.normals, count: vertexFloats))
        indices = Array(UnsafeBufferPointer(start: mesh.indices, count: Int(mesh.triangleCount) * 3))

        groups = (0..<Int(mesh.groupCount)).map { i in
            let g = mesh.groups[i]
            return MeshGroup(firstIndex: g.firstIndex,
                             indexCount: g.indexCount,
                             rgba: (g.rgba.0, g.rgba.1, g.rgba.2, g.rgba.3))
        }

        bboxMin = SIMD3<Float>(mesh.bboxMin.0, mesh.bboxMin.1, mesh.bboxMin.2)
        bboxMax = SIMD3<Float>(mesh.bboxMax.0, mesh.bboxMax.1, mesh.bboxMax.2)
        info = mesh.info.map { String(cString: $0) } ?? ""
    }
}

// MARK: - Serialisation

private let kMagic: UInt32 = 0x43414450   // "CADP"
private let kVersion: UInt32 = 2

extension MeshData {

    func serialised() -> Data {
        var out = Data()
        func append<T>(_ value: T) {
            withUnsafeBytes(of: value) { out.append(contentsOf: $0) }
        }
        func appendArray<T>(_ array: [T]) {
            array.withUnsafeBytes { out.append(contentsOf: $0) }
        }

        let infoBytes = Array(info.utf8)

        append(kMagic)
        append(kVersion)
        append(UInt32(positions.count))
        append(UInt32(normals.count))
        append(UInt32(indices.count))
        append(UInt32(groups.count))
        append(UInt32(infoBytes.count))
        for v in [bboxMin.x, bboxMin.y, bboxMin.z, bboxMax.x, bboxMax.y, bboxMax.z] { append(v) }

        out.append(contentsOf: infoBytes)
        appendArray(positions)
        appendArray(normals)
        appendArray(indices)
        for g in groups {
            append(g.firstIndex); append(g.indexCount)
            append(g.rgba.0); append(g.rgba.1); append(g.rgba.2); append(g.rgba.3)
        }
        return out
    }

    init?(serialised data: Data) {
        var offset = 0
        func read<T>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            defer { offset += size }
            return data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: T.self)
            }
        }
        func readArray<T>(_ type: T.Type, count: Int) -> [T]? {
            let size = MemoryLayout<T>.size * count
            guard offset + size <= data.count else { return nil }
            defer { offset += size }
            return data.withUnsafeBytes { raw -> [T] in
                let base = raw.baseAddress!.advanced(by: offset)
                return Array(UnsafeBufferPointer(
                    start: base.assumingMemoryBound(to: T.self), count: count))
            }
        }

        guard let magic = read(UInt32.self), magic == kMagic,
              let version = read(UInt32.self), version == kVersion,
              let positionCount = read(UInt32.self),
              let normalCount = read(UInt32.self),
              let indexCount = read(UInt32.self),
              let groupCount = read(UInt32.self),
              let infoLength = read(UInt32.self)
        else { return nil }

        var box = [Float]()
        for _ in 0..<6 {
            guard let v = read(Float.self) else { return nil }
            box.append(v)
        }
        bboxMin = SIMD3<Float>(box[0], box[1], box[2])
        bboxMax = SIMD3<Float>(box[3], box[4], box[5])

        guard let infoBytes = readArray(UInt8.self, count: Int(infoLength)) else { return nil }
        info = String(decoding: infoBytes, as: UTF8.self)

        guard let p = readArray(Float.self, count: Int(positionCount)),
              let n = readArray(Float.self, count: Int(normalCount)),
              let i = readArray(UInt32.self, count: Int(indexCount))
        else { return nil }
        positions = p; normals = n; indices = i

        groups = []
        groups.reserveCapacity(Int(groupCount))
        for _ in 0..<Int(groupCount) {
            guard let first = read(UInt32.self), let count = read(UInt32.self),
                  let r = read(Float.self), let g = read(Float.self),
                  let b = read(Float.self), let a = read(Float.self)
            else { return nil }
            groups.append(MeshGroup(firstIndex: first, indexCount: count, rgba: (r, g, b, a)))
        }
    }
}

// MARK: - Cache

/// Parsing STEP is the expensive part — a 56 MB assembly costs ~19 s, and that
/// cost is in reading the text, not in meshing, so it cannot be tuned away.
/// Caching the tessellated result makes every look after the first instant.
enum MeshCache {

    private static let byteBudget = 512 * 1024 * 1024

    private static var directory: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("MacCADPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Keyed on path, size and modification time, so editing a file in Fusion
    /// and re-exporting invalidates the entry without any explicit purge.
    private static func key(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let modified = attrs[.modificationDate] as? Date
        else { return nil }

        let identity = "\(url.path)|\(size)|\(modified.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func load(for url: URL) -> MeshData? {
        guard let dir = directory, let key = key(for: url) else { return nil }
        let file = dir.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        // Touch it so pruning evicts genuinely cold entries first.
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: file.path)
        return MeshData(serialised: data)
    }

    static func store(_ mesh: MeshData, for url: URL) {
        guard let dir = directory, let key = key(for: url) else { return }
        let file = dir.appendingPathComponent(key)
        try? mesh.serialised().write(to: file, options: .atomic)
        prune()
    }

    private static func prune() {
        guard let dir = directory,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return }

        var total = 0
        var items: [(url: URL, size: Int, date: Date)] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.fileSizeKey,
                                                             .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let date = values?.contentModificationDate ?? .distantPast
            total += size
            items.append((entry, size, date))
        }
        guard total > byteBudget else { return }

        // Oldest first until we are back under budget.
        for item in items.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: item.url)
            total -= item.size
            if total <= byteBudget { break }
        }
    }
}
