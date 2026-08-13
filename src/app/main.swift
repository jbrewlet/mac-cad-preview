import Cocoa

// Minimal host app. Its only real job is to be a container that macOS can
// register the Quick Look extension from — an .appex cannot be installed
// on its own. Launching it once is what makes pluginkit notice the extension.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

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

        let text = NSTextField(labelWithString: """
        Mac CAD Preview is installed.

        Select a STEP, IGES or STL file
        in Finder and press the spacebar.

        You can quit this app — the Quick Look
        extension keeps working without it.
        """)
        text.alignment = .center
        text.translatesAutoresizingMaskIntoConstraints = false
        text.maximumNumberOfLines = 0

        let content = window.contentView!
        content.addSubview(text)
        NSLayoutConstraint.activate([
            text.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            text.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            text.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.85),
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
