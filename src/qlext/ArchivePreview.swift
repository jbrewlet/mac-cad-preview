import Cocoa

struct ArchiveLoadError: Error {
    let message: String
}

/// Lists the members of a zip, rar or 7z archive for the Quick Look panel.
/// Names and sizes come from archive headers; nothing is extracted.
enum ArchivePreview {

    static let pathExtensions: Set<String> = ["zip", "rar", "7z"]

    /// A huge archive should not stall the panel. Names after this cap are
    /// counted for the summary and then dropped.
    private static let maxEntries = 10_000

    struct Entry {
        var path: String
        var size: Int64?
        var isDirectory: Bool
        var isEncrypted: Bool
    }

    struct Document {
        var entries: [Entry]
        var info: String
    }

    static func isArchive(_ url: URL) -> Bool {
        pathExtensions.contains(url.pathExtension.lowercased())
    }

    static func load(from url: URL) -> Result<Document, ArchiveLoadError> {
        guard let raw = archivelist_read(url.path, Int32(maxEntries)) else {
            return .failure(ArchiveLoadError(message: "Out of memory."))
        }
        defer { archivelist_free(raw) }

        if let error = raw.pointee.error {
            return .failure(ArchiveLoadError(message: String(cString: error)))
        }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(raw.pointee.count))
        if let base = raw.pointee.entries {
            for index in 0..<Int(raw.pointee.count) {
                let item = base.advanced(by: index).pointee
                guard let path = item.path else { continue }
                let name = String(cString: path)
                guard !name.isEmpty else { continue }
                entries.append(Entry(
                    path: name,
                    size: item.size >= 0 ? item.size : nil,
                    isDirectory: item.is_directory != 0,
                    isEncrypted: item.is_encrypted != 0
                ))
            }
        }

        let info = summary(
            files: Int(raw.pointee.file_count),
            folders: Int(raw.pointee.dir_count),
            bytes: raw.pointee.total_size,
            encrypted: Int(raw.pointee.encrypted_count),
            truncated: raw.pointee.truncated != 0,
            shown: entries.count,
            omitted: Int(raw.pointee.omitted)
        )
        return .success(Document(entries: entries, info: info))
    }

    static func rendered(_ document: Document, fontSize: CGFloat) -> NSAttributedString {
        listing(document.entries, fontSize: fontSize)
    }

    // MARK: - Listing

    private final class Node {
        let name: String
        var children: [String: Node] = [:]
        var isDirectory = false
        var size: Int64?
        var isEncrypted = false

        init(name: String) { self.name = name }
    }

    private static func listing(_ entries: [Entry], fontSize: CGFloat) -> NSAttributedString {
        let root = Node(name: "")
        root.isDirectory = true
        for entry in entries {
            insert(entry, into: root)
        }

        let size = PreviewPreferences.clamped(fontSize)
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let folderFont = NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
        let output = NSMutableAttributedString()

        func walk(_ node: Node, depth: Int) {
            let kids = node.children.values.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            for child in kids {
                append(child, depth: depth, font: font, folderFont: folderFont, into: output)
                if child.isDirectory {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        if output.length == 0 {
            output.append(NSAttributedString(
                string: "Empty",
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
        }
        return output
    }

    private static func insert(_ entry: Entry, into root: Node) {
        let parts = entry.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return }
        var node = root
        for (index, part) in parts.enumerated() {
            let last = index == parts.count - 1
            if node.children[part] == nil {
                node.children[part] = Node(name: part)
            }
            let next = node.children[part]!
            if last {
                next.isDirectory = entry.isDirectory
                next.size = entry.size
                next.isEncrypted = entry.isEncrypted
            } else {
                next.isDirectory = true
            }
            node = next
        }
    }

    private static func append(_ node: Node,
                               depth: Int,
                               font: NSFont,
                               folderFont: NSFont,
                               into output: NSMutableAttributedString) {
        if output.length > 0 {
            output.append(NSAttributedString(string: "\n"))
        }

        let indent = String(repeating: "  ", count: depth)
        let label = node.isDirectory ? "\(node.name)/" : node.name
        let sizeText: String
        if node.isDirectory {
            sizeText = ""
        } else if let bytes = node.size {
            sizeText = Self.bytes(bytes)
        } else {
            sizeText = "—"
        }

        let line = NSMutableAttributedString()
        line.append(NSAttributedString(
            string: indent + label,
            attributes: [
                .font: node.isDirectory ? folderFont : font,
                .foregroundColor: node.isDirectory ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
        ))
        if !sizeText.isEmpty {
            line.append(NSAttributedString(
                string: "    \(sizeText)",
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            ))
        }
        if node.isEncrypted {
            line.append(NSAttributedString(
                string: "  encrypted",
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
        }
        output.append(line)
    }

    private static func summary(files: Int,
                                folders: Int,
                                bytes: Int64,
                                encrypted: Int,
                                truncated: Bool,
                                shown: Int,
                                omitted: Int) -> String {
        var parts: [String] = []
        if truncated {
            parts.append("First \(shown.formatted(.number)) of \((shown + omitted).formatted(.number)) entries")
        } else {
            parts.append(count(files, one: "file", many: "files"))
            if folders > 0 {
                parts.append(count(folders, one: "folder", many: "folders"))
            }
        }
        if bytes > 0 {
            parts.append(Self.bytes(bytes))
        }
        if encrypted > 0 {
            parts.append("encrypted")
        }
        return parts.joined(separator: " · ")
    }

    private static func count(_ n: Int, one: String, many: String) -> String {
        n == 1 ? "1 \(one)" : "\(n.formatted(.number)) \(many)"
    }

    private static func bytes(_ count: Int64) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1_048_576 {
            let kb = Double(count) / 1024
            return String(format: kb >= 10 ? "%.0f KB" : "%.1f KB", kb)
        }
        if count < 1_073_741_824 {
            let mb = Double(count) / 1_048_576
            return String(format: mb >= 10 ? "%.0f MB" : "%.1f MB", mb)
        }
        let gb = Double(count) / 1_073_741_824
        return String(format: gb >= 10 ? "%.0f GB" : "%.1f GB", gb)
    }
}
