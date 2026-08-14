import Cocoa

/// Colours a G-code program for the Quick Look text preview.
///
/// Word-address codes (`G1`, `X10.5`, `M3`) and the two comment forms
/// (`(…)`, `;…`) are recognised. Unknown text is left in the default
/// colour so odd dialects still read as plain code rather than a mess.
enum GCodeHighlighter {

    static func font(size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: PreviewPreferences.clamped(size), weight: .regular)
    }

    private struct Palette {
        let comment: NSColor
        let gCode: NSColor
        let mCode: NSColor
        let axis: NSColor
        let feed: NSColor
        let tool: NSColor
        let lineNumber: NSColor
        let other: NSColor
    }

    private static func palette(for theme: GCodeTheme) -> Palette {
        switch theme {
        case .plain:
            return Palette(comment: .secondaryLabelColor, gCode: .labelColor,
                           mCode: .labelColor, axis: .labelColor, feed: .labelColor,
                           tool: .labelColor, lineNumber: .tertiaryLabelColor,
                           other: .labelColor)
        case .muted:
            return Palette(
                comment: .secondaryLabelColor,
                gCode: adaptive(dark: (0.55, 0.68, 0.82), light: (0.25, 0.40, 0.58)),
                mCode: adaptive(dark: (0.70, 0.66, 0.80), light: (0.42, 0.36, 0.58)),
                axis: adaptive(dark: (0.50, 0.72, 0.68), light: (0.22, 0.42, 0.40)),
                feed: adaptive(dark: (0.80, 0.68, 0.55), light: (0.55, 0.38, 0.28)),
                tool: adaptive(dark: (0.78, 0.72, 0.48), light: (0.50, 0.42, 0.22)),
                lineNumber: .tertiaryLabelColor,
                other: .labelColor)
        case .colourful:
            return Palette(
                comment: .secondaryLabelColor,
                gCode: adaptive(dark: (0.37, 0.69, 1.00), light: (0.04, 0.42, 0.80)),
                mCode: adaptive(dark: (0.77, 0.71, 0.99), light: (0.49, 0.23, 0.93)),
                axis: adaptive(dark: (0.37, 0.92, 0.83), light: (0.06, 0.46, 0.43)),
                feed: adaptive(dark: (0.99, 0.73, 0.45), light: (0.76, 0.25, 0.05)),
                tool: adaptive(dark: (0.99, 0.83, 0.30), light: (0.63, 0.38, 0.03)),
                lineNumber: .tertiaryLabelColor,
                other: .labelColor)
        }
    }

    private static func adaptive(dark: (CGFloat, CGFloat, CGFloat),
                                 light: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.isDark ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }

    static func highlight(_ source: String,
                          fontSize: CGFloat = PreviewPreferences.gcodeFontSize,
                          theme: GCodeTheme = PreviewPreferences.gcodeTheme) -> NSAttributedString {
        let output = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: font(size: fontSize),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        let colors = palette(for: theme)
        let ns = source as NSString
        let length = ns.length
        guard length > 0 else { return output }

        var location = 0
        while location < length {
            let ch = ns.character(at: location)

            if ch == 0x3B { // ';'
                let lineEnd = ns.lineEnd(from: location)
                output.addAttribute(.foregroundColor, value: colors.comment,
                                    range: NSRange(location: location, length: lineEnd - location))
                location = lineEnd
                continue
            }

            if ch == 0x28 { // '('
                let close = ns.index(of: 0x29, from: location + 1) ?? length
                let end = min(close + (close < length ? 1 : 0), length)
                output.addAttribute(.foregroundColor, value: colors.comment,
                                    range: NSRange(location: location, length: end - location))
                location = end
                continue
            }

            if isLetter(ch) {
                let wordEnd = ns.wordEnd(from: location)
                let color = color(for: Character(UnicodeScalar(ch)!).uppercased(), palette: colors)
                output.addAttribute(.foregroundColor, value: color,
                                    range: NSRange(location: location, length: wordEnd - location))
                location = wordEnd
                continue
            }

            location += 1
        }

        return output
    }

    private static func color(for letter: String, palette: Palette) -> NSColor {
        switch letter {
        case "G": return palette.gCode
        case "M": return palette.mCode
        case "X", "Y", "Z", "A", "B", "C", "U", "V", "W", "I", "J", "K", "R": return palette.axis
        case "F", "S": return palette.feed
        case "T", "D", "H": return palette.tool
        case "N": return palette.lineNumber
        default: return palette.other
        }
    }

    private static func isLetter(_ ch: unichar) -> Bool {
        (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A)
    }
}

private extension NSString {
    func lineEnd(from location: Int) -> Int {
        var end = location
        while end < length {
            let ch = character(at: end)
            if ch == 0x0A || ch == 0x0D { break }
            end += 1
        }
        return end
    }

    func index(of target: unichar, from location: Int) -> Int? {
        var i = location
        while i < length {
            if character(at: i) == target { return i }
            i += 1
        }
        return nil
    }

    /// End of a word-address token: the letter plus an optional signed number.
    func wordEnd(from location: Int) -> Int {
        var i = location + 1
        if i < length {
            let sign = character(at: i)
            if sign == 0x2B || sign == 0x2D { i += 1 }
        }
        var seenDot = false
        while i < length {
            let ch = character(at: i)
            if ch >= 0x30 && ch <= 0x39 {
                i += 1
                continue
            }
            if ch == 0x2E && !seenDot {
                seenDot = true
                i += 1
                continue
            }
            break
        }
        return i
    }
}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

struct GCodeLoadError: Error {
    let message: String
}

/// Loads a `.nc` / `.tap` file as highlighted text for Quick Look.
enum GCodePreview {

    static let pathExtensions: Set<String> = ["nc", "tap"]

    /// CAM programs can be tens of megabytes. Colouring the whole file would
    /// stall the panel, so only the start is shown and the rest is noted.
    private static let maxBytes = 1_048_576

    static func isGCode(_ url: URL) -> Bool {
        pathExtensions.contains(url.pathExtension.lowercased())
    }

    static func load(from url: URL) -> Result<(text: NSAttributedString, info: String), GCodeLoadError> {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return .failure(GCodeLoadError(message: "Could not read \(url.lastPathComponent)."))
        }

        if data.isEmpty {
            return .failure(GCodeLoadError(message: "This file is empty."))
        }

        let probe = data.prefix(8192)
        if probe.contains(0) {
            return .failure(GCodeLoadError(message: "This does not look like G-code text. \(url.pathExtension.uppercased()) is also used for binary formats such as NetCDF."))
        }

        let truncated = data.count > maxBytes
        let slice = truncated ? data.prefix(maxBytes) : data[...]
        guard let source = String(data: Data(slice), encoding: .utf8)
                ?? String(data: Data(slice), encoding: .isoLatin1) else {
            return .failure(GCodeLoadError(message: "This file is not readable as text."))
        }

        let lineCount = source.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) } + (source.hasSuffix("\n") ? 0 : 1)
        let info: String
        if truncated {
            info = "First \(Self.bytes(maxBytes)) of \(Self.bytes(data.count)) · \(Self.lines(lineCount)) shown"
        } else {
            info = "\(Self.lines(lineCount)) · \(Self.bytes(data.count))"
        }

        return .success((GCodeHighlighter.highlight(source, fontSize: PreviewPreferences.gcodeFontSize), info))
    }

    private static func bytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1_048_576 {
            let kb = Double(count) / 1024
            return String(format: kb >= 10 ? "%.0f KB" : "%.1f KB", kb)
        }
        let mb = Double(count) / 1_048_576
        return String(format: mb >= 10 ? "%.0f MB" : "%.1f MB", mb)
    }

    private static func lines(_ count: Int) -> String {
        let formatted = count.formatted(.number)
        return count == 1 ? "1 line" : "\(formatted) lines"
    }
}
