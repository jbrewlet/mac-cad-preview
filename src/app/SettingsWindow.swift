import Cocoa

/// Host-app settings. Writes the same plist the Quick Look extension reads.
///
/// Two-column form: labels in a trailing column, controls lined up on the
/// leading edge of the next. The window hugs that form instead of sitting
/// in a large empty frame.
final class SettingsWindow: NSWindow {

    private let colorsCheckbox = NSButton(checkboxWithTitle: "Show by default",
                                          target: nil, action: nil)
    private let edgesCheckbox = NSButton(checkboxWithTitle: "Show by default",
                                         target: nil, action: nil)
    private let projectionPopup = NSPopUpButton()
    private let zoomPopup = NSPopUpButton()
    private let zoomTargetPopup = NSPopUpButton()
    private let upAxisPopup = NSPopUpButton()
    private let initialViewPopup = NSPopUpButton()
    private let wrapPopup = NSPopUpButton()
    private let themePopup = NSPopUpButton()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let stepper = NSStepper()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 1),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Settings"
        isReleasedWhenClosed = false

        colorsCheckbox.target = self
        colorsCheckbox.action = #selector(colorsChanged)
        edgesCheckbox.target = self
        edgesCheckbox.action = #selector(edgesChanged)

        fill(projectionPopup, titles: ["Perspective", "Orthographic"],
             action: #selector(projectionChanged))
        fill(zoomPopup, titles: ["Scroll up zooms in", "Scroll up zooms out"],
             action: #selector(zoomChanged))
        fill(zoomTargetPopup, titles: ZoomTarget.allCases.map(\.title),
             action: #selector(zoomTargetChanged))
        fill(upAxisPopup, titles: UpAxis.allCases.map(\.title),
             action: #selector(upAxisChanged))
        fill(initialViewPopup, titles: InitialView.allCases.map(\.title),
             action: #selector(initialViewChanged))
        fill(wrapPopup, titles: GCodeWrapping.allCases.map(\.title),
             action: #selector(wrapChanged))
        fill(themePopup, titles: GCodeTheme.allCases.map(\.title),
             action: #selector(themeChanged))

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        sizeLabel.setContentHuggingPriority(.required, for: .horizontal)

        stepper.minValue = Double(PreviewPreferences.minimumFontSize)
        stepper.maxValue = Double(PreviewPreferences.maximumFontSize)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepperChanged)

        let fontRow = NSStackView(views: [sizeLabel, stepper])
        fontRow.orientation = .horizontal
        fontRow.alignment = .centerY
        fontRow.spacing = 8

        let note = NSTextField(labelWithString: "Saved for every Quick Look preview.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        let modelGrid = form([
            ("Model colours", colorsCheckbox),
            ("Edges", edgesCheckbox),
            ("Projection", projectionPopup),
            ("Zoom", zoomPopup),
            ("Zoom target", zoomTargetPopup),
            ("Up axis", upAxisPopup),
            ("Initial view", initialViewPopup),
        ])
        let gcodeGrid = form([
            ("Font size", fontRow),
            ("Lines", wrapPopup),
            ("Colours", themePopup),
        ])

        let stack = NSStackView(views: [
            heading("3D preview"),
            modelGrid,
            heading("G-code preview"),
            gcodeGrid,
            note,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: modelGrid)
        stack.setCustomSpacing(18, after: gcodeGrid)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            stack.widthAnchor.constraint(equalToConstant: 400),
        ])

        refresh()
        setContentSize(content.fittingSize)
        center()
    }

    override func becomeKey() {
        super.becomeKey()
        refresh()
    }

    @objc private func colorsChanged() {
        PreviewPreferences.showModelColors = (colorsCheckbox.state == .on)
    }

    @objc private func edgesChanged() {
        PreviewPreferences.showEdges = (edgesCheckbox.state == .on)
    }

    @objc private func projectionChanged() {
        PreviewPreferences.orthographic = (projectionPopup.indexOfSelectedItem == 1)
    }

    @objc private func zoomChanged() {
        PreviewPreferences.scrollUpZoomsIn = (zoomPopup.indexOfSelectedItem == 0)
    }

    @objc private func zoomTargetChanged() {
        PreviewPreferences.zoomTarget = ZoomTarget.allCases[zoomTargetPopup.indexOfSelectedItem]
    }

    @objc private func upAxisChanged() {
        PreviewPreferences.upAxis = UpAxis.allCases[upAxisPopup.indexOfSelectedItem]
    }

    @objc private func initialViewChanged() {
        PreviewPreferences.initialView = InitialView.allCases[initialViewPopup.indexOfSelectedItem]
    }

    @objc private func wrapChanged() {
        PreviewPreferences.gcodeWrapping = GCodeWrapping.allCases[wrapPopup.indexOfSelectedItem]
    }

    @objc private func themeChanged() {
        PreviewPreferences.gcodeTheme = GCodeTheme.allCases[themePopup.indexOfSelectedItem]
    }

    @objc private func stepperChanged() {
        PreviewPreferences.gcodeFontSize = CGFloat(stepper.intValue)
        refreshFontSize()
    }

    private func refresh() {
        colorsCheckbox.state = PreviewPreferences.showModelColors ? .on : .off
        edgesCheckbox.state = PreviewPreferences.showEdges ? .on : .off
        projectionPopup.selectItem(at: PreviewPreferences.orthographic ? 1 : 0)
        zoomPopup.selectItem(at: PreviewPreferences.scrollUpZoomsIn ? 0 : 1)
        zoomTargetPopup.selectItem(at: ZoomTarget.allCases.firstIndex(of: PreviewPreferences.zoomTarget) ?? 0)
        upAxisPopup.selectItem(at: UpAxis.allCases.firstIndex(of: PreviewPreferences.upAxis) ?? 0)
        initialViewPopup.selectItem(at: InitialView.allCases.firstIndex(of: PreviewPreferences.initialView) ?? 0)
        wrapPopup.selectItem(at: GCodeWrapping.allCases.firstIndex(of: PreviewPreferences.gcodeWrapping) ?? 0)
        themePopup.selectItem(at: GCodeTheme.allCases.firstIndex(of: PreviewPreferences.gcodeTheme) ?? 0)
        refreshFontSize()
    }

    private func refreshFontSize() {
        sizeLabel.stringValue = "\(Int(PreviewPreferences.gcodeFontSize)) pt"
        stepper.intValue = Int32(PreviewPreferences.gcodeFontSize)
    }

    private func heading(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return field
    }

    private func form(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { row in
            let label = NSTextField(labelWithString: row.0)
            label.alignment = .right
            return [label, row.1]
        })
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.xPlacement = .fill
        grid.yPlacement = .center
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 0).width = 108
        return grid
    }

    private func fill(_ popup: NSPopUpButton, titles: [String], action: Selector) {
        popup.removeAllItems()
        popup.addItems(withTitles: titles)
        popup.target = self
        popup.action = action
    }
}
