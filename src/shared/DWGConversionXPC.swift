import Foundation

/// Converts a DWG to DXF in a separate sandboxed service. Files travel as open
/// handles, so the service never needs access to the user's folders.
@objc(DWGConversionXPCProtocol)
protocol DWGConversionXPCProtocol {
    /// Replies with nil on success, or a message to show in the preview.
    func convert(dwg: FileHandle, into dxf: FileHandle, reply: @escaping (String?) -> Void)
}

enum DWGConversionServiceName {
    static let bundleID = "com.maccadpreview.dwgconverter"
}
