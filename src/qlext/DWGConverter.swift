import Foundation

/// DWG is a closed format. LibreDWG's `dwg2dxf`, bundled as a separate
/// program, converts it to DXF for the DXF reader. Quick Look extensions may
/// not start programs, so a sandboxed XPC service runs the converter and
/// streams the DXF back through a file handle.
enum DWGConverter {

    private static let pathExtensions: Set<String> = ["dwg"]
    /// The service gives the converter 20 seconds; this covers copying too.
    private static let timeout: TimeInterval = 40
    private static let maxInputBytes: Int64 = 256 * 1024 * 1024

    static func isDWG(_ url: URL) -> Bool {
        pathExtensions.contains(url.pathExtension.lowercased())
    }

    /// Converts `url` to a temporary DXF, hands it to `load`, then removes it.
    static func withConvertedDXF(from url: URL,
                                 onProgress: (String) -> Void,
                                 load: (URL) -> Result<MeshData, MeshLoadError>) -> Result<MeshData, MeshLoadError> {
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
           size.int64Value > maxInputBytes {
            return .failure(MeshLoadError(message: "This DWG file is too large to preview (over 256 MB)."))
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("drawing.dxf")
        let dwg: FileHandle
        let dxf: FileHandle
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
                return .failure(MeshLoadError(message: "Could not prepare to convert this DWG file."))
            }
            dwg = try FileHandle(forReadingFrom: url)
            dxf = try FileHandle(forWritingTo: output)
        } catch {
            return .failure(MeshLoadError(message: "Could not prepare to convert this DWG file."))
        }

        onProgress("Converting DWG…")
        let message = convert(dwg: dwg, into: dxf)
        try? dwg.close()
        try? dxf.close()
        if let message {
            return .failure(MeshLoadError(message: message))
        }

        switch load(output) {
        case .failure(let error):
            return .failure(MeshLoadError(
                message: error.message.replacingOccurrences(of: "DXF file", with: "DWG file")))
        case .success(var mesh):
            mesh.info = mesh.info.replacingOccurrences(of: "\nDXF · ", with: "\nDWG · ")
            return .success(mesh)
        }
    }

    /// Asks the conversion service to fill `dxf`. Returns an error message, or nil.
    private static func convert(dwg: FileHandle, into dxf: FileHandle) -> String? {
        let connection = NSXPCConnection(serviceName: DWGConversionServiceName.bundleID)
        connection.remoteObjectInterface = NSXPCInterface(with: DWGConversionXPCProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let lock = NSLock()
        var result: String?? = .none
        let finished = DispatchSemaphore(value: 0)
        let finish: (String?) -> Void = { message in
            lock.lock()
            defer { lock.unlock() }
            guard result == nil else { return }
            result = .some(message)
            finished.signal()
        }

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            qlLog.error("DWG conversion service failed: \(String(describing: error), privacy: .public)")
            finish("Could not start the DWG converter.")
        }
        guard let converter = proxy as? DWGConversionXPCProtocol else {
            return "Could not start the DWG converter."
        }
        converter.convert(dwg: dwg, into: dxf, reply: finish)

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            finish("This DWG file took too long to convert.")
        }
        lock.lock()
        defer { lock.unlock() }
        return result ?? "This DWG file took too long to convert."
    }
}
