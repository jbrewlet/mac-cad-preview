import Cocoa
import Quartz
import SceneKit
import simd
import os

let qlLog = Logger(subsystem: "com.maccadpreview", category: "preview")

/// Carries the human-readable reason a file could not be shown, so it can be
/// put straight in front of the user.
struct MeshLoadError: Error {
    let message: String
}

@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {

    private var sceneView: CADSceneView!
    private var textScrollView: NSScrollView!
    private var textView: NSTextView!
    private var infoLabel: ClickableLabel!
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var colorToggle: NSButton!
    private var edgesToggle: NSButton!
    private var orthoToggle: NSButton!
    private var viewToggleBox: NSStackView!
    private var fontSizeBox: NSStackView!
    private var fontSizeLabel: NSTextField!
    private var smallerFontButton: NSButton!
    private var largerFontButton: NSButton!
    private var markdownModeControl: NSSegmentedControl!
    private var openInFusionButton: FusionOpenButton!
    private var settingsLink: NSButton!

    private var previewURL: URL?
    private var markdownSource: String?
    private var archiveDocument: ArchivePreview.Document?
    private var isMarkdownPreview = false
    private var isArchivePreview = false

    /// The neutral finish used when the colour toggle is off.
    private static let uniformColor = NSColor(srgbRed: 0.72, green: 0.74, blue: 0.78, alpha: 1)

    private var geometryMaterials: [SCNMaterial] = []
    private var originalColors: [NSColor] = []
    private var edgeNode: SCNNode?
    private var cameraNode: SCNNode?
    private var modelRadius: Float = 1
    private var copyableDimensions = ""
    private var displayedInfo = ""
    private var infoRestoreToken = 0
    private var progressIsLarge = false

    // MARK: - View

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        root.wantsLayer = true

        sceneView = CADSceneView(frame: root.bounds)
        sceneView.autoresizingMask = [.width, .height]
        sceneView.allowsCameraControl = true          // orbit / zoom / pan
        sceneView.antialiasingMode = .multisampling4X
        sceneView.backgroundColor = .clear
        sceneView.rendersContinuously = false
        root.addSubview(sceneView)

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: root.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        textScrollView = NSScrollView(frame: root.bounds)
        textScrollView.autoresizingMask = [.width, .height]
        textScrollView.hasVerticalScroller = true
        textScrollView.hasHorizontalScroller = false
        textScrollView.autohidesScrollers = true
        textScrollView.borderType = .noBorder
        textScrollView.drawsBackground = true
        textScrollView.backgroundColor = .textBackgroundColor
        textScrollView.documentView = textView
        textScrollView.automaticallyAdjustsContentInsets = false
        textScrollView.contentInsets = NSEdgeInsets(top: 28, left: 0, bottom: 28, right: 0)
        textScrollView.isHidden = true
        root.addSubview(textScrollView)

        // Model dimensions etc., bottom-left. Click copies the bbox.
        infoLabel = ClickableLabel(labelWithString: "")
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.maximumNumberOfLines = 0
        infoLabel.isHidden = true
        root.addSubview(infoLabel)

        // Centred message for loading / errors.
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 0
        statusLabel.preferredMaxLayoutWidth = 420
        root.addSubview(statusLabel)

        spinner = NSProgressIndicator()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        root.addSubview(spinner)

        edgesToggle = NSButton(checkboxWithTitle: "Edges",
                               target: self,
                               action: #selector(toggleEdges(_:)))
        edgesToggle.controlSize = .small
        edgesToggle.font = .systemFont(ofSize: 11)
        edgesToggle.state = PreviewPreferences.showEdges ? .on : .off
        edgesToggle.toolTip = "Draw feature edges on the shaded model"

        orthoToggle = NSButton(checkboxWithTitle: "Ortho",
                               target: self,
                               action: #selector(toggleOrtho(_:)))
        orthoToggle.controlSize = .small
        orthoToggle.font = .systemFont(ofSize: 11)
        orthoToggle.state = PreviewPreferences.orthographic ? .on : .off
        orthoToggle.toolTip = "Orthographic projection"

        // Shown only when the model actually has more than one colour.
        colorToggle = NSButton(checkboxWithTitle: "Model colours",
                               target: self,
                               action: #selector(toggleColors(_:)))
        colorToggle.controlSize = .small
        colorToggle.font = .systemFont(ofSize: 11)
        colorToggle.state = PreviewPreferences.showModelColors ? .on : .off
        colorToggle.isHidden = true

        viewToggleBox = NSStackView(views: [edgesToggle, orthoToggle, colorToggle])
        viewToggleBox.orientation = .vertical
        viewToggleBox.alignment = .trailing
        viewToggleBox.spacing = 2
        viewToggleBox.translatesAutoresizingMaskIntoConstraints = false
        viewToggleBox.isHidden = true
        root.addSubview(viewToggleBox)

        smallerFontButton = NSButton(title: "A−", target: self, action: #selector(smallerGCodeFont))
        smallerFontButton.bezelStyle = .roundRect
        smallerFontButton.controlSize = .small
        smallerFontButton.font = .systemFont(ofSize: 11)
        smallerFontButton.toolTip = "Smaller G-code text"

        largerFontButton = NSButton(title: "A+", target: self, action: #selector(largerGCodeFont))
        largerFontButton.bezelStyle = .roundRect
        largerFontButton.controlSize = .small
        largerFontButton.font = .systemFont(ofSize: 11)
        largerFontButton.toolTip = "Larger G-code text"

        fontSizeLabel = NSTextField(labelWithString: "")
        fontSizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        fontSizeLabel.textColor = .secondaryLabelColor
        fontSizeLabel.setContentHuggingPriority(.required, for: .horizontal)

        fontSizeBox = NSStackView(views: [smallerFontButton, fontSizeLabel, largerFontButton])
        fontSizeBox.orientation = .horizontal
        fontSizeBox.alignment = .centerY
        fontSizeBox.spacing = 6
        fontSizeBox.translatesAutoresizingMaskIntoConstraints = false
        fontSizeBox.isHidden = true
        root.addSubview(fontSizeBox)

        markdownModeControl = NSSegmentedControl(
            labels: MarkdownViewMode.allCases.map(\.title),
            trackingMode: .selectOne,
            target: self,
            action: #selector(markdownModeChanged)
        )
        markdownModeControl.segmentStyle = .rounded
        markdownModeControl.controlSize = .small
        markdownModeControl.font = .systemFont(ofSize: 11)
        markdownModeControl.translatesAutoresizingMaskIntoConstraints = false
        markdownModeControl.isHidden = true
        markdownModeControl.toolTip = "Show rendered Markdown or the original source"
        root.addSubview(markdownModeControl)

        openInFusionButton = FusionOpenButton()
        openInFusionButton.isHidden = true
        openInFusionButton.onClick = { [weak self] in self?.openInFusion() }
        root.addSubview(openInFusionButton, positioned: .above, relativeTo: sceneView)

        settingsLink = NSButton(title: "Settings", target: self, action: #selector(openSettings))
        settingsLink.bezelStyle = .inline
        settingsLink.isBordered = false
        settingsLink.font = .systemFont(ofSize: 11)
        settingsLink.contentTintColor = .secondaryLabelColor
        settingsLink.translatesAutoresizingMaskIntoConstraints = false
        settingsLink.toolTip = "Open Mac CAD Preview settings"
        root.addSubview(settingsLink)

        NSLayoutConstraint.activate([
            settingsLink.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            settingsLink.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),

            openInFusionButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            openInFusionButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),

            viewToggleBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            viewToggleBox.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            fontSizeBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            fontSizeBox.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            markdownModeControl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            markdownModeControl.bottomAnchor.constraint(equalTo: fontSizeBox.topAnchor, constant: -6),

            infoLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            infoLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

            statusLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor,
                                               multiplier: 0.8),

            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),
        ])

        self.view = root

        // Quick Look sizes the panel from this, clamped to the screen. Without
        // it the panel falls back to the frame above, which is smaller than a
        // 3D view really wants.
        preferredContentSize = NSSize(width: 1000, height: 750)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyTextWrapping(to: textScrollView.contentView.bounds.width)
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        // Quick Look does not promise to call this on the main thread, and it
        // kills extensions that take too long. So: put the panel on screen
        // immediately, report success, and fill in geometry when it arrives.
        // A 56 MB STEP file takes ~19 s to parse — far past any QL timeout.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.previewURL = url
            self.openInFusionButton.isHidden = !FusionOpener.isAvailable(for: url)
            self.statusLabel.stringValue = "Opening \(url.lastPathComponent)…"
            self.spinner.startAnimation(nil)
            handler(nil)
        }

        if MarkdownPreview.isMarkdown(url) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let started = CFAbsoluteTimeGetCurrent()
                switch MarkdownPreview.load(from: url) {
                case .failure(let error):
                    DispatchQueue.main.async { self?.showFailure(error.message) }
                case .success(let document):
                    let elapsed = CFAbsoluteTimeGetCurrent() - started
                    DispatchQueue.main.async {
                        self?.presentMarkdown(document.source, info: document.info, elapsed: elapsed)
                    }
                }
            }
            return
        }

        if ArchivePreview.isArchive(url) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let started = CFAbsoluteTimeGetCurrent()
                switch ArchivePreview.load(from: url) {
                case .failure(let error):
                    DispatchQueue.main.async { self?.showFailure(error.message) }
                case .success(let document):
                    let elapsed = CFAbsoluteTimeGetCurrent() - started
                    DispatchQueue.main.async {
                        self?.presentArchive(document, elapsed: elapsed)
                    }
                }
            }
            return
        }

        if GCodePreview.isGCode(url) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let started = CFAbsoluteTimeGetCurrent()
                switch GCodePreview.load(from: url) {
                case .failure(let error):
                    DispatchQueue.main.async { self?.showFailure(error.message) }
                case .success(let document):
                    let elapsed = CFAbsoluteTimeGetCurrent() - started
                    DispatchQueue.main.async {
                        self?.presentGCode(document.text, info: document.info, elapsed: elapsed)
                    }
                }
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = CFAbsoluteTimeGetCurrent()

            let meshData: MeshData
            var cached = true
            if let hit = MeshCache.load(for: url) {
                meshData = hit
            } else {
                cached = false
                DispatchQueue.main.async { self?.showParseProgress(for: url) }
                switch Self.parseMesh(at: url, onProgress: { [weak self] stage in
                    DispatchQueue.main.async { self?.showLoadStage(stage) }
                }) {
                case .failure(let error):
                    DispatchQueue.main.async { self?.showFailure(error.message) }
                    return
                case .success(let parsed):
                    meshData = parsed
                    MeshCache.store(parsed, for: url)
                }
            }

            let (geometry, colors) = Self.makeGeometry(from: meshData)
            let edges = MeshEdges.geometry(from: meshData)
            let elapsed = CFAbsoluteTimeGetCurrent() - started

            DispatchQueue.main.async {
                self?.present(geometry: geometry, edges: edges, colors: colors,
                              info: meshData.info,
                              bounds: (min: meshData.bboxMin, max: meshData.bboxMax),
                              elapsed: elapsed, cached: cached)
            }
        }
    }

    // MARK: - Presentation

    private func showFailure(_ message: String) {
        spinner.stopAnimation(nil)
        statusLabel.stringValue = message
        sceneView.isHidden = true
        textScrollView.isHidden = true
        fontSizeBox.isHidden = true
        markdownModeControl.isHidden = true
        viewToggleBox.isHidden = true
        isMarkdownPreview = false
        isArchivePreview = false
        markdownSource = nil
        archiveDocument = nil
        infoLabel.onClick = nil
        infoLabel.toolTip = nil
    }

    private func presentMarkdown(_ source: String, info: String, elapsed: Double) {
        spinner.stopAnimation(nil)
        statusLabel.stringValue = ""
        sceneView.isHidden = true
        viewToggleBox.isHidden = true
        openInFusionButton.isHidden = true
        copyableDimensions = ""
        infoLabel.onClick = nil
        infoLabel.toolTip = nil

        isMarkdownPreview = true
        isArchivePreview = false
        markdownSource = source
        archiveDocument = nil
        let mode = PreviewPreferences.markdownViewMode
        markdownModeControl.selectedSegment = MarkdownViewMode.allCases.firstIndex(of: mode) ?? 0
        markdownModeControl.isHidden = false
        smallerFontButton.toolTip = "Smaller Markdown text"
        largerFontButton.toolTip = "Larger Markdown text"

        applyMarkdownContent()
        textView.scrollToBeginningOfDocument(nil)
        textScrollView.isHidden = false
        refreshFontSizeControls()
        fontSizeBox.isHidden = false

        displayedInfo = info
        infoLabel.stringValue = info
        infoLabel.isHidden = false

        qlLog.info("markdown presented in \(elapsed, format: .fixed(precision: 2))s")
    }

    private func presentGCode(_ text: NSAttributedString, info: String, elapsed: Double) {
        spinner.stopAnimation(nil)
        statusLabel.stringValue = ""
        sceneView.isHidden = true
        viewToggleBox.isHidden = true
        markdownModeControl.isHidden = true
        openInFusionButton.isHidden = true
        isMarkdownPreview = false
        isArchivePreview = false
        markdownSource = nil
        archiveDocument = nil
        copyableDimensions = ""
        infoLabel.onClick = nil
        infoLabel.toolTip = nil
        smallerFontButton.toolTip = "Smaller G-code text"
        largerFontButton.toolTip = "Larger G-code text"

        textView.textStorage?.setAttributedString(text)
        applyTextWrapping(to: textScrollView.contentView.bounds.width)
        textView.scrollToBeginningOfDocument(nil)
        textScrollView.isHidden = false
        refreshFontSizeControls()
        fontSizeBox.isHidden = false

        displayedInfo = info
        infoLabel.stringValue = info
        infoLabel.isHidden = false

        qlLog.info("gcode highlighted in \(elapsed, format: .fixed(precision: 2))s")
    }

    private func presentArchive(_ document: ArchivePreview.Document, elapsed: Double) {
        spinner.stopAnimation(nil)
        statusLabel.stringValue = ""
        sceneView.isHidden = true
        viewToggleBox.isHidden = true
        markdownModeControl.isHidden = true
        openInFusionButton.isHidden = true
        isMarkdownPreview = false
        isArchivePreview = true
        markdownSource = nil
        archiveDocument = document
        copyableDimensions = ""
        infoLabel.onClick = nil
        infoLabel.toolTip = nil
        smallerFontButton.toolTip = "Smaller archive listing text"
        largerFontButton.toolTip = "Larger archive listing text"

        applyArchiveContent()
        textView.scrollToBeginningOfDocument(nil)
        textScrollView.isHidden = false
        refreshFontSizeControls()
        fontSizeBox.isHidden = false

        displayedInfo = document.info
        infoLabel.stringValue = document.info
        infoLabel.isHidden = false

        qlLog.info("archive listed in \(elapsed, format: .fixed(precision: 2))s")
    }

    private func present(geometry: SCNGeometry,
                         edges: SCNGeometry?,
                         colors: [NSColor],
                         info: String,
                         bounds: (min: SIMD3<Float>, max: SIMD3<Float>),
                         elapsed: Double,
                         cached: Bool) {
        spinner.stopAnimation(nil)
        statusLabel.stringValue = ""
        textScrollView.isHidden = true
        fontSizeBox.isHidden = true
        markdownModeControl.isHidden = true
        isMarkdownPreview = false
        isArchivePreview = false
        markdownSource = nil
        archiveDocument = nil
        sceneView.isHidden = false
        viewToggleBox.isHidden = false

        geometryMaterials = geometry.materials
        originalColors = colors
        // With a single colour there is nothing to switch between, so the
        // toggle would just be clutter.
        colorToggle.isHidden = (colors.count < 2)
        if colors.count >= 2 {
            colorToggle.state = PreviewPreferences.showModelColors ? .on : .off
            applyModelColors(colorToggle.state == .on)
        }

        let scene = SCNScene()

        let node = SCNNode(geometry: geometry)
        // CAD models are rarely modelled near the origin, so recentre on the
        // bounding box before the camera ever looks at it.
        let centre = (bounds.min + bounds.max) * 0.5
        let pivot = SCNMatrix4MakeTranslation(CGFloat(centre.x),
                                              CGFloat(centre.y),
                                              CGFloat(centre.z))
        node.pivot = pivot

        // CAD tools treat +Z as up; SceneKit treats +Y as up. The default
        // maps model Z onto scene Y. Y-up skips that, for SceneKit-style files.
        let oriented = SCNNode()
        if PreviewPreferences.upAxis == .zUp {
            oriented.eulerAngles.x = -.pi / 2
        }
        oriented.addChildNode(node)

        if let edges {
            let overlay = SCNNode(geometry: edges)
            overlay.pivot = pivot
            // Nudge the lines off the surface so they do not z-fight the fill.
            overlay.scale = SCNVector3(1.001, 1.001, 1.001)
            overlay.renderingOrder = 1
            overlay.isHidden = !PreviewPreferences.showEdges
            oriented.addChildNode(overlay)
            edgeNode = overlay
        } else {
            edgeNode = nil
        }
        edgesToggle.state = PreviewPreferences.showEdges ? .on : .off
        scene.rootNode.addChildNode(oriented)

        let extent = bounds.max - bounds.min
        let radius = max(max(extent.x, extent.y), extent.z)
        modelRadius = radius

        let camera = SCNCamera()
        camera.zNear = Double(radius) * 0.001
        camera.zFar  = Double(radius) * 100
        camera.wantsHDR = false

        let aspect = Self.viewAspect(of: sceneView)
        let fit = Self.fitCamera(boundsMin: bounds.min, boundsMax: bounds.max,
                                 zUp: PreviewPreferences.upAxis == .zUp,
                                 aspect: aspect,
                                 fieldOfView: camera.fieldOfView)
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = fit.position
        cameraNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cameraNode)
        self.cameraNode = cameraNode

        let key = SCNLight()
        key.type = .directional
        key.intensity = 700
        let keyNode = SCNNode()
        keyNode.light = key
        let cam = fit.position
        let camDist = sqrt(cam.x * cam.x + cam.y * cam.y + cam.z * cam.z)
        let lift = max(CGFloat(radius) * 0.25, camDist * 0.15)
        keyNode.position = SCNVector3(cam.x, cam.y + lift, cam.z)
        keyNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .ambient
        fill.intensity = 380
        let fillNode = SCNNode()
        fillNode.light = fill
        scene.rootNode.addChildNode(fillNode)

        sceneView.scene = scene
        sceneView.pointOfView = cameraNode
        sceneView.isHidden = false
        // Orbit around the model, and give the zoom a sane fallback target for
        // when the pointer is over empty space.
        sceneView.orbitTarget = SCNVector3Zero
        sceneView.modelRadius = CGFloat(radius)
        sceneView.defaultCameraController.target = SCNVector3Zero

        orthoToggle.state = PreviewPreferences.orthographic ? .on : .off
        applyProjection(PreviewPreferences.orthographic)

        let size = extent
        copyableDimensions = String(format: "%.1f × %.1f × %.1f",
                                    Double(size.x), Double(size.y), Double(size.z))
        displayedInfo = info
        infoRestoreToken += 1
        infoLabel.stringValue = info
        infoLabel.isHidden = false
        infoLabel.toolTip = "Copy dimensions"
        infoLabel.onClick = { [weak self] in self?.copyDimensions() }

        qlLog.info("rendered in \(elapsed, format: .fixed(precision: 2))s (cached: \(cached))")
    }

    // MARK: - Geometry

    /// Builds the geometry, with one element (and one material) per colour the
    /// file declared. Returns the per-element colours so they can be restored
    /// after switching to the uniform look.
    private static func makeGeometry(from mesh: MeshData) -> (SCNGeometry, [NSColor]) {
        let vertexCount = mesh.vertexCount

        let positionData = mesh.positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let normalData = mesh.normals.withUnsafeBufferPointer { Data(buffer: $0) }

        let positions = SCNGeometrySource(
            data: positionData, semantic: .vertex, vectorCount: vertexCount,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3)

        let normals = SCNGeometrySource(
            data: normalData, semantic: .normal, vectorCount: vertexCount,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3)

        var elements: [SCNGeometryElement] = []
        var colors: [NSColor] = []
        var alphas: [CGFloat] = []

        for group in mesh.groups {
            let start = Int(group.firstIndex)
            let count = Int(group.indexCount)
            guard count > 0, start + count <= mesh.indices.count else { continue }

            let slice = Array(mesh.indices[start..<(start + count)])
            let data = slice.withUnsafeBufferPointer { Data(buffer: $0) }

            elements.append(SCNGeometryElement(
                data: data, primitiveType: .triangles,
                primitiveCount: count / 3,
                bytesPerIndex: MemoryLayout<UInt32>.size))

            colors.append(NSColor(srgbRed: CGFloat(group.rgba.0),
                                  green: CGFloat(group.rgba.1),
                                  blue: CGFloat(group.rgba.2),
                                  alpha: 1.0))
            alphas.append(CGFloat(group.rgba.3))
        }

        let geometry = SCNGeometry(sources: [positions, normals], elements: elements)

        geometry.materials = colors.enumerated().map { index, color in
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = color
            material.metalness.contents = 0.15
            material.roughness.contents = 0.45
            // CAD exports frequently contain inconsistently oriented faces;
            // drawing both sides avoids holes where a normal points the wrong way.
            material.isDoubleSided = true
            let alpha = alphas[index]
            if alpha < 0.99 {
                material.transparency = alpha
                material.blendMode = .alpha
            }
            return material
        }

        return (geometry, colors)
    }

    /// Same view directions as before; distance is computed by `fitCamera`.
    private static func cameraDirection() -> SIMD3<Float> {
        switch PreviewPreferences.initialView {
        case .isometric:
            return simd_normalize(SIMD3<Float>(1, 0.9, 1))
        case .front:
            return simd_normalize(SIMD3<Float>(0, 0.15, 1.9))
        case .top:
            return simd_normalize(SIMD3<Float>(0, 1, 0.001))
        }
    }

    private static func viewAspect(of view: NSView) -> Double {
        let size = view.bounds.size
        if size.width > 1, size.height > 1 {
            return Double(size.width / size.height)
        }
        return 1000 / 750
    }

    /// Places the camera so the centred, oriented bbox fills the view with a
    /// light margin. Padding 1.10 leaves about 5% on each side, enough to
    /// clear the overlay chrome without shrinking the part.
    private static func fitCamera(boundsMin: SIMD3<Float>,
                                  boundsMax: SIMD3<Float>,
                                  zUp: Bool,
                                  aspect: Double,
                                  fieldOfView: Double,
                                  padding: Double = 1.10) -> (position: SCNVector3, orthographicScale: Double) {
        let half = (boundsMax - boundsMin) * 0.5
        var corners: [SIMD3<Float>] = []
        corners.reserveCapacity(8)
        for sx: Float in [-1, 1] {
            for sy: Float in [-1, 1] {
                for sz: Float in [-1, 1] {
                    var point = SIMD3(sx * half.x, sy * half.y, sz * half.z)
                    if zUp {
                        point = SIMD3(point.x, point.z, -point.y)
                    }
                    corners.append(point)
                }
            }
        }

        let toCamera = cameraDirection()
        let forward = -toCamera
        var worldUp = SIMD3<Float>(0, 1, 0)
        if abs(simd_dot(forward, worldUp)) > 0.98 {
            worldUp = SIMD3<Float>(0, 0, 1)
        }
        let right = simd_normalize(simd_cross(forward, worldUp))
        let up = simd_cross(right, forward)

        let vHalf = tan(fieldOfView * .pi / 360)
        let hHalf = vHalf * max(aspect, 0.1)
        var distance = 0.0
        var maxX = 0.0
        var maxY = 0.0
        for point in corners {
            let toward = Double(simd_dot(point, toCamera))
            let x = abs(Double(simd_dot(point, right)))
            let y = abs(Double(simd_dot(point, up)))
            distance = max(distance, toward + x / hHalf)
            distance = max(distance, toward + y / vHalf)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }

        let radius = max(simd_length(half), 1e-4)
        distance = max(distance * padding, Double(radius) * 0.5)
        let position = toCamera * Float(distance)
        let scale = max(maxY, maxX / max(aspect, 0.1)) * padding
        return (SCNVector3(position.x, position.y, position.z),
                max(scale, Double(radius) * 0.05))
    }

    // MARK: - Open in Fusion / Settings

    private func openInFusion() {
        guard let url = previewURL else { return }
        FusionOpener.requestOpen(url)
    }

    @objc private func openSettings() {
        HostApp.requestOpenSettings()
    }

    private func applyTextWrapping(to width: CGFloat) {
        guard width > 0 else { return }
        let wrap = isMarkdownPreview ||
            (!isArchivePreview && PreviewPreferences.gcodeWrapping == .wrap)
        textView.isHorizontallyResizable = !wrap
        textView.textContainer?.widthTracksTextView = wrap
        textScrollView.hasHorizontalScroller = !wrap
        if wrap {
            textView.frame.size.width = width
            textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        } else {
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                           height: CGFloat.greatestFiniteMagnitude)
        }
    }

    // MARK: - Colour toggle

    // MARK: - G-code font size

    @objc private func smallerGCodeFont() {
        changeTextFontSize(by: -1)
    }

    @objc private func largerGCodeFont() {
        changeTextFontSize(by: 1)
    }

    @objc private func markdownModeChanged() {
        let index = markdownModeControl.selectedSegment
        guard MarkdownViewMode.allCases.indices.contains(index) else { return }
        PreviewPreferences.markdownViewMode = MarkdownViewMode.allCases[index]
        applyMarkdownContent()
    }

    private func changeTextFontSize(by delta: CGFloat) {
        if isMarkdownPreview {
            let next = PreviewPreferences.clamped(PreviewPreferences.markdownFontSize + delta)
            PreviewPreferences.markdownFontSize = next
            applyMarkdownContent()
        } else if isArchivePreview {
            let next = PreviewPreferences.clamped(PreviewPreferences.archiveFontSize + delta)
            PreviewPreferences.archiveFontSize = next
            applyArchiveContent()
        } else {
            let next = PreviewPreferences.clamped(PreviewPreferences.gcodeFontSize + delta)
            PreviewPreferences.gcodeFontSize = next
            applyGCodeFontSize(next)
        }
        refreshFontSizeControls()
    }

    private func applyMarkdownContent() {
        guard let source = markdownSource else { return }
        let size = PreviewPreferences.markdownFontSize
        let text: NSAttributedString
        switch PreviewPreferences.markdownViewMode {
        case .rendered:
            text = MarkdownPreview.rendered(source, fontSize: size)
        case .source:
            text = MarkdownPreview.sourceText(source, fontSize: size)
        }
        textView.textStorage?.setAttributedString(text)
        applyTextWrapping(to: textScrollView.contentView.bounds.width)
    }

    private func applyArchiveContent() {
        guard let document = archiveDocument else { return }
        let text = ArchivePreview.rendered(document, fontSize: PreviewPreferences.archiveFontSize)
        textView.textStorage?.setAttributedString(text)
        applyTextWrapping(to: textScrollView.contentView.bounds.width)
    }

    private func applyGCodeFontSize(_ size: CGFloat) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        storage.addAttribute(.font, value: GCodeHighlighter.font(size: size),
                             range: NSRange(location: 0, length: storage.length))
    }

    private func refreshFontSizeControls() {
        let size: CGFloat
        if isMarkdownPreview {
            size = PreviewPreferences.markdownFontSize
        } else if isArchivePreview {
            size = PreviewPreferences.archiveFontSize
        } else {
            size = PreviewPreferences.gcodeFontSize
        }
        fontSizeLabel.stringValue = "\(Int(size)) pt"
        smallerFontButton.isEnabled = size > PreviewPreferences.minimumFontSize
        largerFontButton.isEnabled = size < PreviewPreferences.maximumFontSize
    }

    @objc private func toggleColors(_ sender: NSButton) {
        let showOriginal = (sender.state == .on)
        PreviewPreferences.showModelColors = showOriginal
        applyModelColors(showOriginal)
    }

    private func applyModelColors(_ showOriginal: Bool) {
        for (index, material) in geometryMaterials.enumerated() {
            material.diffuse.contents = showOriginal
                ? originalColors[index]
                : Self.uniformColor
        }
    }

    @objc private func toggleEdges(_ sender: NSButton) {
        let show = (sender.state == .on)
        PreviewPreferences.showEdges = show
        edgeNode?.isHidden = !show
    }

    @objc private func toggleOrtho(_ sender: NSButton) {
        let ortho = (sender.state == .on)
        PreviewPreferences.orthographic = ortho
        applyProjection(ortho)
    }

    /// Keeps the current framing when switching between perspective and ortho.
    /// Uses the view's live camera — SceneKit's orbit controller may not be
    /// the node we originally created.
    private func applyProjection(_ ortho: Bool) {
        guard let node = sceneView.pointOfView ?? cameraNode,
              let camera = node.camera else { return }
        let target = sceneView.orbitTarget
        let pos = node.worldPosition
        let dx = Double(pos.x - target.x)
        let dy = Double(pos.y - target.y)
        let dz = Double(pos.z - target.z)
        let distance = sqrt(dx * dx + dy * dy + dz * dz)
        let tanHalf = tan(camera.fieldOfView * .pi / 360)

        if ortho {
            if !camera.usesOrthographicProjection, tanHalf > 0 {
                camera.orthographicScale = max(Double(modelRadius) * 0.05,
                                               distance * tanHalf)
            }
            camera.usesOrthographicProjection = true
        } else {
            if camera.usesOrthographicProjection, tanHalf > 0, distance > 1e-9 {
                let desired = camera.orthographicScale / tanHalf
                let scale = desired / distance
                node.worldPosition = SCNVector3(target.x + CGFloat(dx * scale),
                                                target.y + CGFloat(dy * scale),
                                                target.z + CGFloat(dz * scale))
            }
            camera.usesOrthographicProjection = false
        }

        cameraNode = node
        sceneView.pointOfView = node
        // rendersContinuously is off, so a camera-property change would
        // otherwise sit unseen until the next orbit.
        sceneView.rendersContinuously = true
        DispatchQueue.main.async { [weak self] in
            self?.sceneView.rendersContinuously = false
        }
    }

    @objc private func copyDimensions() {
        guard !copyableDimensions.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyableDimensions, forType: .string)

        infoRestoreToken += 1
        let token = infoRestoreToken
        let previous = displayedInfo
        let rest = previous.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        infoLabel.stringValue = (["Copied \(copyableDimensions)"] + rest)
            .joined(separator: "\n")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.infoRestoreToken == token else { return }
            self.infoLabel.stringValue = previous
        }
    }

    // MARK: - Load progress

    /// Hand the C buffers straight into Swift storage so OpenCASCADE's
    /// allocation can be released before we start building the scene.
    private static func parseMesh(at url: URL,
                                  onProgress: @escaping (String) -> Void) -> Result<MeshData, MeshLoadError> {
        let box = LoadProgress(onProgress)
        let retained = Unmanaged.passRetained(box)
        defer { retained.release() }
        guard let handle = cadmesh_load(url.path, -1, reportLoadProgress, retained.toOpaque()) else {
            return .failure(MeshLoadError(message: "Out of memory."))
        }
        defer { cadmesh_free(handle) }
        let mesh = handle.pointee
        if let error = mesh.error {
            return .failure(MeshLoadError(message: String(cString: error)))
        }
        return .success(MeshData(copying: mesh))
    }

    private static let reportLoadProgress: cadmesh_progress_fn = { stage, context in
        guard let stage, let context else { return }
        Unmanaged<LoadProgress>.fromOpaque(context).takeUnretainedValue()
            .report(String(cString: stage))
    }

    private func showParseProgress(for url: URL) {
        let name = url.lastPathComponent
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        let ext = url.pathExtension.lowercased()
        let isBRep = ["step", "stp", "p21", "iges", "igs"].contains(ext)
        progressIsLarge = isBRep && bytes > 1_048_576

        let sized = bytes > 0 ? "\(name) (\(Self.bytes(bytes)))" : name
        if isBRep {
            showLoadStage(progressIsLarge
                          ? "Parsing \(sized)…"
                          : "Parsing \(name)…")
        } else {
            showLoadStage("Reading \(name)…")
        }
    }

    private func showLoadStage(_ stage: String) {
        // Keep the filename-and-size line Swift already put up; the C callback
        // repeats "Parsing STEP…" without that detail.
        if stage.hasPrefix("Parsing"), statusLabel.stringValue.contains("Parsing") {
            return
        }
        let name = previewURL?.lastPathComponent ?? ""
        let display: String
        if stage.hasPrefix("Tessellating"), !name.isEmpty {
            display = "Tessellating \(name)…"
        } else {
            display = stage
        }
        if progressIsLarge && display.lowercased().contains("pars") {
            let hint = display.hasSuffix("…") ? String(display.dropLast()) : display
            statusLabel.stringValue = "\(hint)…\nFirst preview of a large file can take a while."
        } else {
            statusLabel.stringValue = display
        }
    }

    private static func bytes(_ count: Int64) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1_048_576 {
            let kb = Double(count) / 1024
            return String(format: kb >= 10 ? "%.0f KB" : "%.1f KB", kb)
        }
        let mb = Double(count) / 1_048_576
        return String(format: mb >= 10 ? "%.0f MB" : "%.1f MB", mb)
    }
}

/// Box so the C progress callback can reach Swift without a cycle.
private final class LoadProgress {
    let report: (String) -> Void
    init(_ report: @escaping (String) -> Void) { self.report = report }
}

/// Feature and boundary edges from a triangle mesh, for the shaded+edges overlay.
/// Tessellation edges on smooth faces are dropped; a 25° dihedral keeps splits,
/// holes and sharp corners.
enum MeshEdges {

    private static let sharpDot: Float = 0.9063   // cos 25°

    static func geometry(from mesh: MeshData) -> SCNGeometry? {
        let positions = mesh.positions
        let indices = mesh.indices
        guard positions.count >= 9, indices.count >= 3 else { return nil }

        let extent = mesh.bboxMax - mesh.bboxMin
        let diagonal = max(simd_length(extent), 1e-6)
        let scale = 1 / max(diagonal * 1e-5, 1e-5)

        struct Quantized: Hashable {
            let x, y, z: Int32
        }
        struct Key: Hashable {
            let a, b: Quantized
        }
        struct Record {
            var p0: SIMD3<Float>
            var p1: SIMD3<Float>
            var normals: [SIMD3<Float>]
        }

        func quantize(_ p: SIMD3<Float>) -> Quantized {
            Quantized(x: Int32((p.x * scale).rounded()),
                      y: Int32((p.y * scale).rounded()),
                      z: Int32((p.z * scale).rounded()))
        }
        func key(_ p: SIMD3<Float>, _ q: SIMD3<Float>) -> Key {
            let a = quantize(p), b = quantize(q)
            if (a.x, a.y, a.z) < (b.x, b.y, b.z) { return Key(a: a, b: b) }
            return Key(a: b, b: a)
        }
        func vertex(_ index: UInt32) -> SIMD3<Float>? {
            let i = Int(index) * 3
            guard i + 2 < positions.count else { return nil }
            return SIMD3(positions[i], positions[i + 1], positions[i + 2])
        }

        var edges: [Key: Record] = [:]
        var i = 0
        while i + 2 < indices.count {
            defer { i += 3 }
            guard let pa = vertex(indices[i]),
                  let pb = vertex(indices[i + 1]),
                  let pc = vertex(indices[i + 2]) else { continue }
            let n = simd_cross(pb - pa, pc - pa)
            let len = simd_length(n)
            let normal = len > 1e-12 ? n / len : SIMD3<Float>(0, 0, 1)
            for pair in [(pa, pb), (pb, pc), (pc, pa)] {
                let k = key(pair.0, pair.1)
                if edges[k] != nil {
                    edges[k]!.normals.append(normal)
                } else {
                    edges[k] = Record(p0: pair.0, p1: pair.1, normals: [normal])
                }
            }
        }

        var linePositions: [Float] = []
        var lineIndices: [UInt32] = []
        linePositions.reserveCapacity(edges.count * 6)
        lineIndices.reserveCapacity(edges.count * 2)

        for record in edges.values {
            let keep: Bool
            if record.normals.count < 2 {
                keep = true
            } else {
                keep = record.normals.contains { a in
                    record.normals.contains { b in simd_dot(a, b) < sharpDot }
                }
            }
            guard keep else { continue }
            let base = UInt32(linePositions.count / 3)
            linePositions.append(contentsOf: [record.p0.x, record.p0.y, record.p0.z,
                                              record.p1.x, record.p1.y, record.p1.z])
            lineIndices.append(base)
            lineIndices.append(base + 1)
        }
        guard lineIndices.count >= 2 else { return nil }

        let positionData = linePositions.withUnsafeBufferPointer { Data(buffer: $0) }
        let indexData = lineIndices.withUnsafeBufferPointer { Data(buffer: $0) }
        let source = SCNGeometrySource(
            data: positionData, semantic: .vertex,
            vectorCount: linePositions.count / 3,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3)
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .line,
            primitiveCount: lineIndices.count / 2,
            bytesPerIndex: MemoryLayout<UInt32>.size)

        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 0.85)
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }
}

/// Label that copies on click when `onClick` is set.
final class ClickableLabel: NSTextField {
    var onClick: (() -> Void)? {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    override func mouseDown(with event: NSEvent) {
        if let onClick {
            onClick()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        if onClick != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}

/// SceneKit's built-in camera control always zooms toward the centre of the
/// view, in a fixed direction. Taking over the scroll wheel lets the zoom go
/// toward whatever is under the pointer — the behaviour every CAD app has —
/// while orbit and pan stay with the built-in controller.
final class CADSceneView: SCNView {

    var orbitTarget = SCNVector3Zero
    var modelRadius: CGFloat = 1

    override func scrollWheel(with event: NSEvent) {
        guard let pov = pointOfView else {
            super.scrollWheel(with: event)
            return
        }

        // Trackpads report fine-grained deltas; a mouse wheel reports coarse
        // notches. Normalise so both feel the same.
        var delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= 8 }
        if !PreviewPreferences.scrollUpZoomsIn { delta = -delta }
        guard delta != 0 else { return }

        // Default: scroll up / swipe up = zoom in. Invertible in Settings.
        let step = min(abs(delta) * 0.004, 0.3)
        let fraction = delta > 0 ? step : -step

        // Default: zoom toward the point under the pointer. Settings can
        // switch that to the window centre (the model orbit target).
        let target: SCNVector3
        if PreviewPreferences.zoomTarget == .pointer {
            let point = convert(event.locationInWindow, from: nil)
            let hits = hitTest(point, options: [
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
                .ignoreHiddenNodes: true,
            ])
            target = hits.first?.worldCoordinates ?? orbitTarget
        } else {
            target = orbitTarget
        }

        // Ortho zoom is a scale change; moving the camera does nothing visible.
        if let camera = pov.camera, camera.usesOrthographicProjection {
            let factor = delta > 0 ? (1 - step) : (1 + step)
            let minScale = Double(max(modelRadius * 0.01, 1e-4))
            let maxScale = Double(modelRadius) * 20
            camera.orthographicScale = min(maxScale, max(minScale, camera.orthographicScale * Double(factor)))
            orbitTarget = target
            defaultCameraController.target = target
            return
        }

        let position = pov.worldPosition
        let toTarget = SCNVector3(target.x - position.x,
                                  target.y - position.y,
                                  target.z - position.z)
        let distance = sqrt(toTarget.x * toTarget.x +
                            toTarget.y * toTarget.y +
                            toTarget.z * toTarget.z)

        // Never let the camera reach or pass through the surface it is
        // approaching, or the view flips inside out.
        let minDistance = max(modelRadius * 0.01, 1e-4)
        var travel = distance * fraction
        if distance - travel < minDistance {
            travel = distance - minDistance
        }
        guard distance > 0, travel != 0 else { return }

        let unit = SCNVector3(toTarget.x / distance,
                              toTarget.y / distance,
                              toTarget.z / distance)
        pov.worldPosition = SCNVector3(position.x + unit.x * travel,
                                       position.y + unit.y * travel,
                                       position.z + unit.z * travel)

        // Re-anchor the orbit on what we zoomed into, so rotating afterwards
        // turns around the detail being inspected rather than the whole part.
        orbitTarget = target
        defaultCameraController.target = target
    }
}
