import Cocoa
import Foundation

final class OpenInFusionXPCService: NSObject, OpenInFusionXPCProtocol, NSXPCListenerDelegate {

    func openInFusion(path: String, reply: @escaping (Bool) -> Void) {
        FusionOpener.openInFusion(path: path, reply: reply)
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: OpenInFusionXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }
}

let service = OpenInFusionXPCService()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
RunLoop.main.run()
