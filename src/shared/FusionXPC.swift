import Foundation

@objc(OpenInFusionXPCProtocol)
protocol OpenInFusionXPCProtocol {
    func openInFusion(path: String, reply: @escaping (Bool) -> Void)
    func openSettings(reply: @escaping (Bool) -> Void)
}

enum FusionXPCServiceName {
    static let bundleID = "com.maccadpreview.helper"
}
