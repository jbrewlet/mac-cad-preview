import Cocoa

struct MarkdownLoadError: Error {
    let message: String
}

/// Loads a Markdown file and builds the two Quick Look presentations:
/// rendered CommonMark, and the original source in a monospaced font.
enum MarkdownPreview {

    static let pathExtensions: Set<String> = ["md", "markdown"]

    /// Same cap as G-code: colouring or laying out a huge file would stall
    /// the panel, so only the start is shown and the rest is noted.
    private static let maxBytes = 1_048_576

    static func isMarkdown(_ url: URL) -> Bool {
        pathExtensions.contains(url.pathExtension.lowercased())
    }

    static func load(from url: URL) -> Result<(source: String, info: String), MarkdownLoadError> {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return .failure(MarkdownLoadError(message: "Could not read \(url.lastPathComponent)."))
        }

        if data.isEmpty {
            return .failure(MarkdownLoadError(message: "This file is empty."))
        }

        let probe = data.prefix(8192)
        if probe.contains(0) {
            return .failure(MarkdownLoadError(message: "This does not look like Markdown text."))
        }

        let truncated = data.count > maxBytes
        let slice = truncated ? data.prefix(maxBytes) : data[...]
        guard let source = String(data: Data(slice), encoding: .utf8)
                ?? String(data: Data(slice), encoding: .isoLatin1) else {
            return .failure(MarkdownLoadError(message: "This file is not readable as text."))
        }

        let lineCount = source.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) } + (source.hasSuffix("\n") ? 0 : 1)
        let info: String
        if truncated {
            info = "First \(Self.bytes(maxBytes)) of \(Self.bytes(data.count)) · \(Self.lines(lineCount)) shown"
        } else {
            info = "\(Self.lines(lineCount)) · \(Self.bytes(data.count))"
        }

        return .success((source, info))
    }

    static func rendered(_ source: String, fontSize: CGFloat) -> NSAttributedString {
        MarkdownRenderer.rendered(source, fontSize: fontSize)
    }

    static func sourceText(_ source: String, fontSize: CGFloat) -> NSAttributedString {
        NSAttributedString(
            string: source,
            attributes: [
                .font: NSFont.monospacedSystemFont(
                    ofSize: PreviewPreferences.clamped(fontSize),
                    weight: .regular
                ),
                .foregroundColor: NSColor.labelColor,
            ]
        )
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

/// Turns Foundation's CommonMark parse into readable preview typography.
/// The parser already strips markers; this only chooses fonts, colour and
/// spacing so a heading looks like a heading rather than bold body text.
enum MarkdownRenderer {

    static func rendered(_ source: String, fontSize: CGFloat) -> NSAttributedString {
        let size = PreviewPreferences.clamped(fontSize)
        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .full
            let parsed = try AttributedString(markdown: source, options: options)
            return style(NSAttributedString(parsed), bodySize: size)
        } catch {
            return MarkdownPreview.sourceText(source, fontSize: size)
        }
    }

    private static func style(_ parsed: NSAttributedString, bodySize: CGFloat) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: parsed)
        let full = NSRange(location: 0, length: output.length)
        guard full.length > 0 else { return output }

        let base = paragraphStyle(spacing: 8, indent: 0)
        output.addAttribute(.font, value: NSFont.systemFont(ofSize: bodySize), range: full)
        output.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        output.addAttribute(.paragraphStyle, value: base, range: full)

        output.enumerateAttribute(.presentationIntentAttributeName, in: full) { value, range, _ in
            guard let intent = value as? PresentationIntent else { return }
            applyBlock(intent, to: output, range: range, bodySize: bodySize)
        }

        output.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            guard let intent = value as? InlinePresentationIntent else { return }
            applyInline(intent, to: output, range: range, bodySize: bodySize)
        }

        output.enumerateAttribute(.link, in: full) { value, range, _ in
            guard value != nil else { return }
            output.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
            output.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }

        insertBlockBreaks(into: output)
        insertListMarkers(into: output)
        return output
    }

    /// `.full` syntax encodes blocks with presentation intents and often
    /// omits the newlines between them. Put a paragraph break at each new
    /// block so the text view can show headings and lists as separate lines.
    private static func insertBlockBreaks(into output: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: output.length)
        var starts: [Int] = []
        var lastID: Int?
        output.enumerateAttribute(.presentationIntentAttributeName, in: full) { value, range, _ in
            guard let intent = value as? PresentationIntent,
                  let id = blockIdentity(intent) else { return }
            if lastID != nil, id != lastID, range.location > 0 {
                starts.append(range.location)
            }
            lastID = id
        }
        for location in starts.reversed() {
            let before = (output.string as NSString).character(at: location - 1)
            if before == 0x0A || before == 0x2029 { continue }
            let attrs = output.attributes(at: max(0, location - 1), effectiveRange: nil)
            output.insert(NSAttributedString(string: "\n", attributes: attrs), at: location)
        }
    }

    private static func blockIdentity(_ intent: PresentationIntent) -> Int? {
        for component in intent.components.reversed() {
            switch component.kind {
            case .header, .paragraph, .listItem, .codeBlock, .blockQuote, .thematicBreak:
                return component.identity
            default:
                continue
            }
        }
        return nil
    }

    /// `.full` markdown syntax strips `-` / `1.` from the text. Put a marker
    /// back at the start of each list item so the rendered view still reads
    /// as a list.
    private static func insertListMarkers(into output: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: output.length)
        var insertions: [(Int, String, [NSAttributedString.Key: Any])] = []
        var seenItems = Set<Int>()
        output.enumerateAttribute(.presentationIntentAttributeName, in: full) { value, range, _ in
            guard let intent = value as? PresentationIntent,
                  let marker = listMarker(intent),
                  let itemID = listItemIdentity(intent),
                  seenItems.insert(itemID).inserted else { return }
            let attrs = output.attributes(at: range.location, effectiveRange: nil)
            insertions.append((range.location, marker, attrs))
        }
        for (location, marker, attrs) in insertions.reversed() {
            output.insert(NSAttributedString(string: marker, attributes: attrs), at: location)
        }
    }

    private static func listItemIdentity(_ intent: PresentationIntent) -> Int? {
        for component in intent.components {
            if case .listItem = component.kind {
                return component.identity
            }
        }
        return nil
    }

    private static func listMarker(_ intent: PresentationIntent) -> String? {
        var ordinal: Int?
        var ordered = false
        for component in intent.components {
            switch component.kind {
            case .listItem(let n):
                ordinal = n
            case .orderedList:
                ordered = true
            case .unorderedList:
                ordered = false
            default:
                break
            }
        }
        guard let ordinal else { return nil }
        return ordered ? "\(ordinal). " : "• "
    }

    private static func applyBlock(_ intent: PresentationIntent,
                                   to output: NSMutableAttributedString,
                                   range: NSRange,
                                   bodySize: CGFloat) {
        var headerLevel: Int?
        var listDepth = 0
        var isCodeBlock = false
        var isQuote = false
        var isThematicBreak = false

        for component in intent.components {
            switch component.kind {
            case .header(let level):
                headerLevel = level
            case .orderedList, .unorderedList:
                listDepth += 1
            case .codeBlock:
                isCodeBlock = true
            case .blockQuote:
                isQuote = true
            case .thematicBreak:
                isThematicBreak = true
            default:
                break
            }
        }

        if let level = headerLevel {
            let scale: CGFloat
            switch level {
            case 1: scale = 1.85
            case 2: scale = 1.45
            case 3: scale = 1.22
            default: scale = 1.08
            }
            let size = max(bodySize, (bodySize * scale).rounded())
            output.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold), range: range)
            output.addAttribute(.paragraphStyle, value: paragraphStyle(spacing: 10, indent: 0), range: range)
        }

        if listDepth > 0 {
            let indent = CGFloat(listDepth) * 22
            output.addAttribute(.paragraphStyle, value: paragraphStyle(spacing: 4, indent: indent), range: range)
        }

        if isCodeBlock {
            output.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: bodySize, weight: .regular),
                                range: range)
            output.addAttribute(.backgroundColor, value: codeFill, range: range)
            output.addAttribute(.paragraphStyle, value: paragraphStyle(spacing: 8, indent: 12), range: range)
        }

        if isQuote {
            output.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            output.addAttribute(.paragraphStyle, value: paragraphStyle(spacing: 8, indent: 16), range: range)
            if let current = output.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
                output.addAttribute(.font, value: italic(current), range: range)
            }
        }

        if isThematicBreak {
            output.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        }
    }

    private static func applyInline(_ intent: InlinePresentationIntent,
                                    to output: NSMutableAttributedString,
                                    range: NSRange,
                                    bodySize: CGFloat) {
        let current = output.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            ?? NSFont.systemFont(ofSize: bodySize)
        var font = current

        if intent.contains(.code) {
            font = NSFont.monospacedSystemFont(ofSize: current.pointSize * 0.92, weight: .regular)
            output.addAttribute(.backgroundColor, value: codeFill, range: range)
        }
        if intent.contains(.stronglyEmphasized) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if intent.contains(.emphasized) {
            font = italic(font)
        }
        if intent.contains(.strikethrough) {
            output.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }

        output.addAttribute(.font, value: font, range: range)
    }

    private static func paragraphStyle(spacing: CGFloat, indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacing
        style.lineSpacing = 2
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        return style
    }

    private static func italic(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    private static let codeFill = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08)
        }
        return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.06)
    }
}
