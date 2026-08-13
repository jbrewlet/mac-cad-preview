import Cocoa
import Quartz
import SceneKit
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
    private var infoLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var colorToggle: NSButton!
    private var openInFusionButton: FusionOpenButton!

    private var previewURL: URL?

    /// The neutral finish used when the colour toggle is off.
    private static let uniformColor = NSColor(srgbRed: 0.72, green: 0.74, blue: 0.78, alpha: 1)

    private var geometryMaterials: [SCNMaterial] = []
    private var originalColors: [NSColor] = []

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

        // Model dimensions etc., bottom-left.
        infoLabel = NSTextField(labelWithString: "")
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

        // Shown only when the model actually has more than one colour.
        colorToggle = NSButton(checkboxWithTitle: "Model colours",
                               target: self,
                               action: #selector(toggleColors(_:)))
        colorToggle.translatesAutoresizingMaskIntoConstraints = false
        colorToggle.state = .on
        colorToggle.controlSize = .small
        colorToggle.font = .systemFont(ofSize: 11)
        colorToggle.isHidden = true
        root.addSubview(colorToggle)

        openInFusionButton = FusionOpenButton()
        openInFusionButton.isHidden = true
        openInFusionButton.onClick = { [weak self] in self?.openInFusion() }
        root.addSubview(openInFusionButton, positioned: .above, relativeTo: sceneView)

        NSLayoutConstraint.activate([
            openInFusionButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            openInFusionButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),

            colorToggle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            colorToggle.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

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
            self.statusLabel.stringValue = "Reading \(url.lastPathComponent)…"
            self.spinner.startAnimation(nil)
            handler(nil)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = CFAbsoluteTimeGetCurrent()

            // Hand the C buffers straight into Swift storage so OpenCASCADE's
            // allocation can be released before we start building the scene.
            func parse() -> Result<MeshData, MeshLoadError> {
                guard let handle = cadmesh_load(url.path, -1) else {
                    return .failure(MeshLoadError(message: "Out of memory."))
                }
                defer { cadmesh_free(handle) }
                let mesh = handle.pointee
                if let error = mesh.error {
                    return .failure(MeshLoadError(message: String(cString: error)))
                }
                return .success(MeshData(copying: mesh))
            }

            let meshData: MeshData
            var cached = true
            if let hit = MeshCache.load(for: url) {
                meshData = hit
            } else {
                cached = false
                switch parse() {
                case .failure(let error):
                    DispatchQueue.main.async { self?.showFailure(error.message) }
                    return
                case .success(let parsed):
                    meshData = parsed
                    MeshCache.store(parsed, for: url)
                }
            }

            let (geometry, colors) = Self.makeGeometry(from: meshData)
            let elapsed = CFAbsoluteTimeGetCurrent() - started

            DispatchQueue.main.async {
                self?.present(geometry: geometry, colors: colors, info: meshData.info,
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
    }

    private func present(geometry: SCNGeometry,
                         colors: [NSColor],
                         info: String,
                         bounds: (min: SIMD3<Float>, max: SIMD3<Float>),
                         elapsed: Double,
                         cached: Bool) {
        spinner.stopAnimation(nil)
        statusLabel.stringValue = ""

        geometryMaterials = geometry.materials
        originalColors = colors
        // With a single colour there is nothing to switch between, so the
        // toggle would just be clutter.
        colorToggle.isHidden = (colors.count < 2)

        let scene = SCNScene()

        let node = SCNNode(geometry: geometry)
        // CAD models are rarely modelled near the origin, so recentre on the
        // bounding box before the camera ever looks at it.
        let centre = (bounds.min + bounds.max) * 0.5
        node.pivot = SCNMatrix4MakeTranslation(CGFloat(centre.x),
                                               CGFloat(centre.y),
                                               CGFloat(centre.z))

        // CAD tools (Fusion, SolidWorks, Inventor) treat +Z as up; SceneKit
        // treats +Y as up. Rotating -90° about X maps model Z onto scene Y, so
        // parts stand the way they were drawn instead of lying on their back.
        let zUp = SCNNode()
        zUp.eulerAngles.x = -.pi / 2
        zUp.addChildNode(node)
        scene.rootNode.addChildNode(zUp)

        let extent = bounds.max - bounds.min
        let radius = max(max(extent.x, extent.y), extent.z)

        let camera = SCNCamera()
        camera.zNear = Double(radius) * 0.001
        camera.zFar  = Double(radius) * 100
        camera.wantsHDR = false
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        // Isometric three-quarter view — front, right and above — which is the
        // convention for presenting a part.
        let d = radius * 1.9
        cameraNode.position = SCNVector3(CGFloat(d), CGFloat(d * 0.9), CGFloat(d))
        cameraNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 700
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(CGFloat(d), CGFloat(d * 1.5), CGFloat(d))
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

        infoLabel.stringValue = info
        infoLabel.isHidden = false

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

    // MARK: - Open in Fusion

    private func openInFusion() {
        guard let url = previewURL else { return }
        FusionOpener.requestOpen(url)
    }

    // MARK: - Colour toggle

    @objc private func toggleColors(_ sender: NSButton) {
        let showOriginal = (sender.state == .on)
        for (index, material) in geometryMaterials.enumerated() {
            material.diffuse.contents = showOriginal
                ? originalColors[index]
                : Self.uniformColor
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
        guard delta != 0 else { return }

        // Scroll up / swipe up = zoom in.
        let step = min(abs(delta) * 0.004, 0.3)
        let fraction = delta > 0 ? step : -step

        // Zoom toward the point under the pointer. If the pointer is over empty
        // space there is nothing to converge on, so fall back to the model.
        let point = convert(event.locationInWindow, from: nil)
        let hits = hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: true,
        ])
        let target = hits.first?.worldCoordinates ?? orbitTarget

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
