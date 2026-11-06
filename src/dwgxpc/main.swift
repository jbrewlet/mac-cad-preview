import Foundation
import os

private let dwgLog = Logger(subsystem: "com.maccadpreview", category: "dwg")

/// Runs LibreDWG's `dwg2dxf`, a separate GPL program, on behalf of the Quick
/// Look extension, whose sandbox does not allow it to start programs. This
/// service has its own sandbox, which the converter inherits: it sees only the
/// handles it is given and this service's temporary folder.
final class DWGConversionService: NSObject, DWGConversionXPCProtocol, NSXPCListenerDelegate {

    private static let timeout: TimeInterval = 20
    private static let maxInputBytes: UInt64 = 256 * 1024 * 1024
    private static let maxOutputBytes: UInt64 = 256 * 1024 * 1024
    private static let chunkSize = 1024 * 1024

    func convert(dwg: FileHandle, into dxf: FileHandle, reply: @escaping (String?) -> Void) {
        reply(Self.convert(dwg: dwg, into: dxf))
    }

    private static func convert(dwg: FileHandle, into dxf: FileHandle) -> String? {
        guard let tool = Bundle.main.url(forAuxiliaryExecutable: "dwg2dxf") else {
            return "The DWG converter is missing from this build."
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return "Could not prepare to convert this DWG file."
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("drawing.dwg")
        let output = directory.appendingPathComponent("drawing.dxf")

        do {
            guard FileManager.default.createFile(atPath: input.path, contents: nil) else {
                return "Could not prepare to convert this DWG file."
            }
            let copy = try FileHandle(forWritingTo: input)
            defer { try? copy.close() }
            guard try Self.copy(from: dwg, to: copy, limit: maxInputBytes) else {
                return "This DWG file is too large to preview (over 256 MB)."
            }
        } catch {
            return "Could not read this DWG file."
        }

        if let message = run(tool, arguments: ["-y", "-o", output.path, input.path], in: directory) {
            return message
        }

        do {
            let converted = try FileHandle(forReadingFrom: output)
            defer { try? converted.close() }
            guard try Self.copy(from: converted, to: dxf, limit: maxOutputBytes) else {
                return "This drawing is too large to preview."
            }
        } catch {
            return "LibreDWG could not read this DWG file."
        }
        return nil
    }

    /// Copies until end of file. Returns false if `source` is longer than `limit`.
    private static func copy(from source: FileHandle, to destination: FileHandle, limit: UInt64) throws -> Bool {
        var total: UInt64 = 0
        while let chunk = try source.read(upToCount: chunkSize), !chunk.isEmpty {
            total += UInt64(chunk.count)
            if total > limit { return false }
            try destination.write(contentsOf: chunk)
        }
        return true
    }

    /// Runs the converter with a deadline. Returns an error message, or nil.
    private static func run(_ tool: URL, arguments: [String], in directory: URL) -> String? {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            dwgLog.error("dwg2dxf failed to launch: \(String(describing: error), privacy: .public)")
            return "Could not start the DWG converter."
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
            return "This DWG file took too long to convert."
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            dwgLog.info("dwg2dxf exited with status \(process.terminationStatus)")
            return "LibreDWG could not read this DWG file."
        }
        return nil
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: DWGConversionXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }
}

let service = DWGConversionService()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
RunLoop.main.run()
