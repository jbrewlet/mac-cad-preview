import Cocoa

// Minimal host app. Its only real job is to be a container that macOS can
// register the Quick Look extension from — an .appex cannot be installed
// on its own. Launching it once is what makes pluginkit notice the extension.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    private static let supportURL = URL(string: "https://buymeacoffee.com/jbrw")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 520, height: 300)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac CAD Preview"
        window.center()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "unknown"

        let headline = NSTextField(labelWithString: "Mac CAD Preview is installed.")
        headline.alignment = .center
        headline.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        headline.translatesAutoresizingMaskIntoConstraints = false

        let versionLine = NSTextField(labelWithString: "Version \(version)")
        versionLine.alignment = .center
        versionLine.font = NSFont.monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        versionLine.textColor = .secondaryLabelColor
        versionLine.translatesAutoresizingMaskIntoConstraints = false

        let body = NSTextField(labelWithString: """
        Select a STEP, IGES, STL or 3MF file
        in Finder and press the spacebar.

        You can quit this app — the Quick Look
        extension keeps working without it.
        """)
        body.alignment = .center
        body.translatesAutoresizingMaskIntoConstraints = false
        body.maximumNumberOfLines = 0

        let coffee = NSButton(
            title: "Buy me a coffee ☕",
            target: self,
            action: #selector(openSupportPage)
        )
        coffee.bezelStyle = .rounded
        coffee.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(headline)
        content.addSubview(versionLine)
        content.addSubview(body)
        content.addSubview(coffee)
        NSLayoutConstraint.activate([
            headline.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            headline.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -72),
            headline.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.85),
            versionLine.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            versionLine.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 6),
            body.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            body.topAnchor.constraint(equalTo: versionLine.bottomAnchor, constant: 20),
            body.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.85),
            coffee.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            coffee.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 28),
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSupportPage() {
        NSWorkspace.shared.open(AppDelegate.supportURL)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
