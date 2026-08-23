import Foundation
import os

private let prefsLog = Logger(subsystem: "com.maccadpreview", category: "preferences")

enum UpAxis: String, CaseIterable {
    case zUp
    case yUp

    var title: String {
        switch self {
        case .zUp: return "Z up (CAD)"
        case .yUp: return "Y up (SceneKit)"
        }
    }
}

enum ZoomTarget: String, CaseIterable {
    case pointer
    case centre

    var title: String {
        switch self {
        case .pointer: return "Toward pointer"
        case .centre: return "Window centre"
        }
    }
}

enum InitialView: String, CaseIterable {
    case isometric
    case front
    case top

    var title: String {
        switch self {
        case .isometric: return "Isometric"
        case .front: return "Front"
        case .top: return "Top"
        }
    }
}

enum GCodeWrapping: String, CaseIterable {
    case wrap
    case scroll

    var title: String {
        switch self {
        case .wrap: return "Wrap lines"
        case .scroll: return "Scroll horizontally"
        }
    }
}

enum GCodeTheme: String, CaseIterable {
    case colourful
    case muted
    case plain

    var title: String {
        switch self {
        case .colourful: return "Colourful"
        case .muted: return "Muted"
        case .plain: return "Plain"
        }
    }
}

enum MarkdownViewMode: String, CaseIterable {
    case rendered
    case source

    var title: String {
        switch self {
        case .rendered: return "Rendered"
        case .source: return "Source"
        }
    }
}

/// Settings shared by the host app and the Quick Look extension.
///
/// There is no Developer ID, so an App Group container is not available.
/// The host app is unsandboxed and writes the same file the sandboxed
/// extension already uses for its cache: the Quick Look container. The
/// next spacebar preview reads whatever was saved.
enum PreviewPreferences {

    static let defaultFontSize: CGFloat = 12
    static let minimumFontSize: CGFloat = 9
    static let maximumFontSize: CGFloat = 24

    private static let fontSizeKey = "gcodeFontSize"
    private static let showModelColorsKey = "showModelColors"
    private static let showEdgesKey = "showEdges"
    private static let orthographicKey = "orthographic"
    private static let scrollUpZoomsInKey = "scrollUpZoomsIn"
    private static let upAxisKey = "upAxis"
    private static let zoomTargetKey = "zoomTarget"
    private static let initialViewKey = "initialView"
    private static let gcodeWrappingKey = "gcodeWrapping"
    private static let gcodeThemeKey = "gcodeTheme"
    private static let markdownViewModeKey = "markdownViewMode"
    private static let markdownFontSizeKey = "markdownFontSize"
    private static let containerBundleID = "com.maccadpreview.quicklook"
    private static let queue = DispatchQueue(label: "com.maccadpreview.preferences")
    private static var cached: [String: Any]?

    static var gcodeFontSize: CGFloat {
        get { queue.sync { clamped(read()[fontSizeKey] as? Double) } }
        set { queue.sync { update(fontSizeKey, Double(clamped(newValue))) } }
    }

    /// Default for the **Model colours** checkbox. On unless the user turns it off.
    static var showModelColors: Bool {
        get { bool(showModelColorsKey, default: true) }
        set { queue.sync { update(showModelColorsKey, newValue) } }
    }

    /// Default for the **Edges** checkbox. On — shaded plus feature edges.
    static var showEdges: Bool {
        get { bool(showEdgesKey, default: true) }
        set { queue.sync { update(showEdgesKey, newValue) } }
    }

    /// Default for the **Ortho** checkbox. Off — perspective, matching the
    /// original camera.
    static var orthographic: Bool {
        get { bool(orthographicKey, default: false) }
        set { queue.sync { update(orthographicKey, newValue) } }
    }

    /// Current behaviour: scroll / swipe up zooms in. Off inverts that.
    static var scrollUpZoomsIn: Bool {
        get { bool(scrollUpZoomsInKey, default: true) }
        set { queue.sync { update(scrollUpZoomsInKey, newValue) } }
    }

    static var upAxis: UpAxis {
        get { value(upAxisKey, default: .zUp) }
        set { queue.sync { update(upAxisKey, newValue.rawValue) } }
    }

    static var zoomTarget: ZoomTarget {
        get { value(zoomTargetKey, default: .pointer) }
        set { queue.sync { update(zoomTargetKey, newValue.rawValue) } }
    }

    static var initialView: InitialView {
        get { value(initialViewKey, default: .isometric) }
        set { queue.sync { update(initialViewKey, newValue.rawValue) } }
    }

    static var gcodeWrapping: GCodeWrapping {
        get { value(gcodeWrappingKey, default: .wrap) }
        set { queue.sync { update(gcodeWrappingKey, newValue.rawValue) } }
    }

    static var gcodeTheme: GCodeTheme {
        get { value(gcodeThemeKey, default: .colourful) }
        set { queue.sync { update(gcodeThemeKey, newValue.rawValue) } }
    }

    /// Default for the Markdown preview: rendered CommonMark, or the raw source.
    static var markdownViewMode: MarkdownViewMode {
        get { value(markdownViewModeKey, default: .rendered) }
        set { queue.sync { update(markdownViewModeKey, newValue.rawValue) } }
    }

    static var markdownFontSize: CGFloat {
        get { queue.sync { clamped(read()[markdownFontSizeKey] as? Double) } }
        set { queue.sync { update(markdownFontSizeKey, Double(clamped(newValue))) } }
    }

    static func clamped(_ size: CGFloat) -> CGFloat {
        min(maximumFontSize, max(minimumFontSize, size.rounded()))
    }

    private static func clamped(_ size: Double?) -> CGFloat {
        clamped(CGFloat(size ?? Double(defaultFontSize)))
    }

    private static func bool(_ key: String, default fallback: Bool) -> Bool {
        queue.sync { (read()[key] as? Bool) ?? fallback }
    }

    private static func value<T: RawRepresentable>(_ key: String, default fallback: T) -> T
    where T.RawValue == String {
        queue.sync {
            if let raw = read()[key] as? String, let parsed = T(rawValue: raw) {
                return parsed
            }
            return fallback
        }
    }

    // MARK: - File

    /// `~/Library/Containers/com.maccadpreview.quicklook/…/MacCADPreview/preferences.plist`
    /// from the host, or the same path via the sandbox home from the extension.
    static var fileURL: URL {
        let folder: URL
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            folder = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask)[0]
                .appendingPathComponent("MacCADPreview", isDirectory: true)
        } else {
            folder = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Containers/\(containerBundleID)/Data/Library/Application Support/MacCADPreview",
                    isDirectory: true)
        }
        return folder.appendingPathComponent("preferences.plist")
    }

    private static func update(_ key: String, _ value: Any) {
        var values = read()
        values[key] = value
        write(values)
    }

    private static func read() -> [String: Any] {
        if let cached { return cached }
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let values = object as? [String: Any] else {
            cached = [:]
            return [:]
        }
        cached = values
        return values
    }

    private static func write(_ values: [String: Any]) {
        cached = values
        let url = fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: values,
                                                          format: .xml,
                                                          options: 0)
            try data.write(to: url, options: .atomic)
        } catch {
            prefsLog.error("Could not save preferences: \(error.localizedDescription, privacy: .public)")
        }
    }
}
