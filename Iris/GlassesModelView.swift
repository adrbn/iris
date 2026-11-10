import SceneKit
import SwiftUI

/// Les lunettes en 3D, procédurales (pas de .usdz des L801) : un tour en 22 s autour de Y,
/// inclinées de 0,16 rad. La LED reflète l'état. Caméra orthographique cadrée sur l'encombrement
/// maximal, donc tout reste visible à toutes les rotations, marge égale en haut et en bas.
struct GlassesModelView: UIViewRepresentable {
    let mood: GlassesMood
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> GlassesScene { GlassesScene() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.isPlaying = true
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let s = context.coordinator
        s.setFrame(dark: scheme == .dark)
        s.setSpin(!reduceMotion)
        s.setLED(mood)
        // Le cadrage dépend du rapport largeur/hauteur, connu seulement après la mise en page.
        DispatchQueue.main.async { s.frame(aspect: view.bounds.height > 0 ? view.bounds.width / view.bounds.height : 3) }
    }

    static func dismantleUIView(_ view: SCNView, coordinator: GlassesScene) {
        view.isPlaying = false
        coordinator.scene.isPaused = true
    }
}

@MainActor
final class GlassesScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let spinner = SCNNode()
    private let model = SCNNode()
    private let frameMaterial = SCNMaterial()
    private let ledMaterial = SCNMaterial()
    private var spinning: Bool?
    private var mood: GlassesMood?
    /// Demi-hauteur et rayon horizontal de l'encombrement, une fois centré.
    private var halfHeight: Float = 3
    private var radiusXZ: Float = 9

    init() {
        frameMaterial.lightingModel = .physicallyBased
        frameMaterial.roughness.contents = 0.35
        frameMaterial.metalness.contents = 0
        frameMaterial.clearCoat.contents = 1
        frameMaterial.clearCoatRoughness.contents = 0.08

        let lens = SCNMaterial()
        lens.lightingModel = .physicallyBased
        lens.diffuse.contents = UIColor(white: 0.06, alpha: 1)
        lens.roughness.contents = 0.05
        lens.metalness.contents = 0.1
        lens.transparency = 0.72
        lens.isDoubleSided = true

        // PBR so the emission (the glow) is what pulses; diffuse stays dark.
        ledMaterial.lightingModel = .physicallyBased
        ledMaterial.diffuse.contents = UIColor.black

        let tilt = SCNNode()
        tilt.eulerAngles.x = 0.16
        scene.rootNode.addChildNode(tilt)
        tilt.addChildNode(spinner)
        spinner.addChildNode(model)
        build(lens: lens)
        center()
        light()

        let cam = SCNCamera()
        cam.usesOrthographicProjection = true
        cam.zNear = 1; cam.zFar = 100
        camera.camera = cam
        camera.position = SCNVector3(0, 0, 40)
        scene.rootNode.addChildNode(camera)
    }

    // MARK: Modèle

    private func build(lens: SCNMaterial) {
        for side: Float in [-1, 1] {
            let rim = SCNShape(path: ring(), extrusionDepth: 0.55)
            rim.chamferRadius = 0.1
            rim.materials = [frameMaterial]
            let rimNode = SCNNode(geometry: rim)
            rimNode.position = SCNVector3(3.45 * side, 0, 0)
            model.addChildNode(rimNode)

            let glass = SCNShape(path: rounded(5.0, 3.9, 1.4), extrusionDepth: 0.12)
            glass.materials = [lens]
            let glassNode = SCNNode(geometry: glass)
            glassNode.position = SCNVector3(3.45 * side, 0, 0)
            model.addChildNode(glassNode)

            // Branche : charnière, segment avant épais, segment arrière fin, embout vers le bas.
            let x = 6.35 * side - 0.2 * side
            let hinge = box(0.6, 0.95, 0.7, at: SCNVector3(x, 1.25, -0.3))
            let front = box(0.5, 0.95, 5.4, at: SCNVector3(x, 1.25, -0.3 - 2.7 - 0.3))
            let back = box(0.34, 0.55, 5, at: SCNVector3(x, 1.2, -6.0 - 2.5))
            // Embout : part du bout de la branche (z = -11) et descend vers l'arrière.
            let tip = box(0.34, 0.5, 2.2, at: SCNVector3(x, 1.2 - 1.1 * sin(0.6), -11 - 1.1 * cos(0.6)))
            tip.eulerAngles.x = -0.6
            [hinge, front, back, tip].forEach(model.addChildNode)
        }

        // Pont : bande en arc entre les deux montures.
        let arc = UIBezierPath(arcCenter: .zero, radius: 0.85, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: true)
        let band = UIBezierPath(cgPath: arc.cgPath.copy(strokingWithWidth: 0.4, lineCap: .round, lineJoin: .round, miterLimit: 1))
        band.flatness = 0.02
        let bridge = SCNShape(path: band, extrusionDepth: 0.45)
        bridge.materials = [frameMaterial]
        let bridgeNode = SCNNode(geometry: bridge)
        bridgeNode.position = SCNVector3(0, 0.75, 0)
        model.addChildNode(bridgeNode)

        // Caméra sur l'avant de la charnière droite, LED sur la gauche.
        let lensBlack = SCNMaterial()
        lensBlack.lightingModel = .physicallyBased
        lensBlack.diffuse.contents = UIColor.black
        lensBlack.roughness.contents = 0.02
        lensBlack.clearCoat.contents = 1
        let cam = SCNCylinder(radius: 0.3, height: 0.25)
        cam.materials = [lensBlack]
        let camNode = SCNNode(geometry: cam)
        camNode.eulerAngles.x = .pi / 2
        camNode.position = SCNVector3(5.75, 1.3, 0.38)
        model.addChildNode(camNode)

        let led = SCNSphere(radius: 0.14)
        led.materials = [ledMaterial]
        let ledNode = SCNNode(geometry: led)
        ledNode.position = SCNVector3(-5.75, 1.3, 0.36)
        ledNode.name = "led"
        model.addChildNode(ledNode)
    }

    private func box(_ w: Float, _ h: Float, _ l: Float, at p: SCNVector3) -> SCNNode {
        let b = SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(l), chamferRadius: CGFloat(min(w, h)) * 0.3)
        b.materials = [frameMaterial]
        let n = SCNNode(geometry: b)
        n.position = p
        return n
    }

    private func rounded(_ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> UIBezierPath {
        // CGPath, not UIBezierPath(roundedRect:): UIKit's continuous-corner version gives SCNShape nothing
        // at this scale (rims and lenses vanished on the iPhone).
        let p = UIBezierPath(cgPath: CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
                                            cornerWidth: r, cornerHeight: r, transform: nil))
        p.flatness = 0.02
        return p
    }

    private func ring() -> UIBezierPath {
        let p = rounded(5.8, 4.6, 1.7)
        p.append(rounded(4.7, 3.5, 1.2))
        p.usesEvenOddFillRule = true
        return p
    }

    /// Centre la boîte englobante sur l'axe de rotation et mesure l'encombrement.
    private func center() {
        let (lo, hi) = model.boundingBox
        let mid = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        model.position = SCNVector3(-mid.x, -mid.y, -mid.z)
        let hx = (hi.x - lo.x) / 2, hy = (hi.y - lo.y) / 2, hz = (hi.z - lo.z) / 2
        radiusXZ = (hx * hx + hz * hz).squareRoot()
        // Inclinaison : la profondeur projette un peu de hauteur.
        halfHeight = hy * cos(0.16) + radiusXZ * sin(0.16)
    }

    private func light() {
        // « Hémisphérique » : environnement clair en haut, sombre en bas.
        let sky = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 64)).image { ctx in
            let colors = [UIColor(white: 1, alpha: 1).cgColor, UIColor(white: 0.35, alpha: 1).cgColor, UIColor(white: 0.05, alpha: 1).cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.5, 1])!
            ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: 64), options: [])
        }
        scene.lightingEnvironment.contents = sky
        scene.lightingEnvironment.intensity = 1.2

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 1100
        key.eulerAngles = SCNVector3(-0.7, 0.5, 0) // haut, droite, devant
        scene.rootNode.addChildNode(key)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .directional
        rim.light?.intensity = 700
        rim.eulerAngles = SCNVector3(-0.3, .pi + 0.6, 0) // arrière gauche
        scene.rootNode.addChildNode(rim)
    }

    // MARK: État

    func frame(aspect: CGFloat) {
        let margin: Float = 1.47 // lunettes 25 % plus petites dans leur cadre (08/11)
        camera.camera?.orthographicScale = Double(max(halfHeight, radiusXZ / Float(max(aspect, 0.1))) * margin)
    }

    func setFrame(dark: Bool) {
        frameMaterial.diffuse.contents = dark ? UIColor(hex: 0x4A4A4E) : UIColor(hex: 0x141414)
    }

    func setSpin(_ on: Bool) {
        guard spinning != on else { return }
        spinning = on
        spinner.removeAllActions()
        if on {
            spinner.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 22)))
        } else {
            spinner.eulerAngles.y = -0.5
        }
    }

    func setLED(_ new: GlassesMood) {
        guard mood != new else { return }
        mood = new
        let node = model.childNode(withName: "led", recursively: false)
        node?.removeAllActions()
        let accent = UIColor(hex: 0xFF5B1F)
        switch new {
        case .off:
            ledMaterial.emission.contents = UIColor.black
            ledMaterial.diffuse.contents = UIColor(white: 0.1, alpha: 1)
        case .video:
            ledMaterial.diffuse.contents = UIColor.black
            ledMaterial.emission.contents = UIColor.systemRed
            ledMaterial.emission.intensity = 1.2
        case .ready, .connecting, .listening:
            ledMaterial.diffuse.contents = UIColor.black
            ledMaterial.emission.contents = accent
            let period = new == .listening ? 0.6 : 2.4
            let material = ledMaterial
            node?.runAction(.repeatForever(.customAction(duration: period) { _, t in
                material.emission.intensity = 1.1 + 0.6 * sin(2 * .pi * t / period)
            }))
        }
    }
}
