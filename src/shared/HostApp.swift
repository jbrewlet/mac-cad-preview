import Cocoa
import os

private let hostLog = Logger(subsystem: "com.maccadpreview", category: "host")

/// Opens the host app's Settings window. The Quick Look extension is
/// sandboxed and cannot launch apps itself, so this goes through the same
/// unsandboxed XPC helper that opens Fusion.
enum HostApp {

    static let bundleID = "com.maccadpreview"
    static let settingsURL = URL(string: "maccadpreview://settings")!

    static func requestOpenSettings() {
        let connection = NSXPCConnection(serviceName: FusionXPCServiceName.bundleID)
        connection.remoteObjectInterface = NSXPCInterface(with: OpenInFusionXPCProtocol.self)
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            hostLog.error("XPC proxy error: \(error.localizedDescription, privacy: .public)")
        }) as? OpenInFusionXPCProtocol else {
            connection.invalidate()
            return
        }

        proxy.openSettings { success in
            if !success {
                hostLog.error("Could not open Settings")
            }
            connection.invalidate()
        }
    }

    static func openSettings(reply: @escaping (Bool) -> Void) {
        if NSWorkspace.shared.open(settingsURL) {
            reply(true)
            return
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            hostLog.error("Mac CAD Preview is not registered with Launch Services")
            reply(false)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.arguments = ["--settings"]
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error {
                hostLog.error("Could not launch host app: \(error.localizedDescription, privacy: .public)")
            }
            reply(error == nil)
        }
    }
}
