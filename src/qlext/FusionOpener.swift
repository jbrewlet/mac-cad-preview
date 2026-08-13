import Cocoa
import os

private let fusionLog = Logger(subsystem: "com.maccadpreview", category: "fusion")

/// Opens CAD files in locally installed Autodesk Fusion.
enum FusionOpener {

    private static let supportedExtensions: Set<String> = [
        "step", "stp", "p21",
        "iges", "igs",
    ]

    private static let bundleIdentifiers = [
        "com.autodesk.dls.streamer.scriptapp.Autodesk-Fusion",
        "com.autodesk.mas.fusion360",
        "com.autodesk.fusion360",
    ]

    private static let applicationPaths = [
        "/Applications/Autodesk Fusion.app",
        "/Applications/Autodesk Fusion 360.app",
        NSHomeDirectory() + "/Applications/Autodesk Fusion.app",
        NSHomeDirectory() + "/Applications/Autodesk Fusion 360.app",
    ]

    static func canOpen(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private static var runningApplication: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            guard let id = app.bundleIdentifier else { return false }
            return bundleIdentifiers.contains(id)
        }
    }

    static var applicationURL: URL? {
        if let running = runningApplication?.bundleURL {
            return running
        }
        for id in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        for path in applicationPaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }

    static func isAvailable(for url: URL) -> Bool {
        canOpen(url) && applicationURL != nil
    }

    // MARK: - Quick Look extension

    /// Sandboxed extensions cannot call Launch Services directly. The embedded
    /// XPC helper (unsandboxed, on-demand) opens Fusion on our behalf.
    static func requestOpen(_ url: URL) {
        guard canOpen(url) else { return }

        let connection = NSXPCConnection(serviceName: FusionXPCServiceName.bundleID)
        connection.remoteObjectInterface = NSXPCInterface(with: OpenInFusionXPCProtocol.self)

        let path = url.path
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            fusionLog.error("XPC proxy error: \(error.localizedDescription, privacy: .public)")
        }) as? OpenInFusionXPCProtocol else {
            connection.invalidate()
            return
        }

        proxy.openInFusion(path: path) { success in
            if success {
                fusionLog.info("Opened \(url.lastPathComponent, privacy: .public) in Fusion")
            } else {
                fusionLog.error("XPC open failed for \(path, privacy: .public)")
            }
            connection.invalidate()
        }
    }

    // MARK: - XPC helper

    static func openInFusion(path: String, reply: @escaping (Bool) -> Void) {
        let url = URL(fileURLWithPath: path)
        guard canOpen(url), let fusion = applicationURL else {
            reply(false)
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = false
        config.allowsRunningApplicationSubstitution = true

        NSWorkspace.shared.open([url], withApplicationAt: fusion,
                                configuration: config) { _, error in
            if let error {
                fusionLog.error("Launch Services failed: \(error.localizedDescription, privacy: .public)")
            }
            reply(error == nil)
        }
    }
}
