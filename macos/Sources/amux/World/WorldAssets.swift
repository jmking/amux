import Foundation
import RealityKit
import AppKit

// MARK: - Asset loading
//
// The world's models are USDZ files in the app's resource bundle, converted
// from CC0 low-poly packs by macos/Assets/convert.py. Each is loaded once as a
// prototype and handed out as clones. Anything that fails to load, or has not
// been converted yet, falls back to a primitive stand-in from WorldPrimitives,
// so the scene runs with boxes before it runs with models. That is also what
// makes the choreography testable independently of the art.

@MainActor
final class WorldAssets {
    static let shared = WorldAssets()

    private var prototypes: [String: Entity] = [:]
    private var inFlight: [String: Task<Entity?, Never>] = [:]
    private(set) var missing: Set<String> = []

    /// Where the converted models live. SwiftPM builds the resource bundle
    /// without an Info.plist, so `Bundle.module` traps; walk real paths the way
    /// the agent icons do.
    static let resourceDir: URL? = {
        var dirs: [URL] = []
        if let res = Bundle.main.resourceURL {
            dirs.append(res.appendingPathComponent("world"))
            dirs.append(res.appendingPathComponent("amux_amux.bundle/world"))
        }
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            dirs.append(exeDir.appendingPathComponent("amux_amux.bundle/world"))
            dirs.append(exeDir.appendingPathComponent("world"))
        }
        return dirs.first { FileManager.default.fileExists(atPath: $0.path) }
    }()

    func url(for name: String) -> URL? {
        guard let dir = Self.resourceDir else { return nil }
        let u = dir.appendingPathComponent(name + ".usdz")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// The shared prototype for a model, loaded on first use. nil when the
    /// file is absent or fails to load; callers then use a primitive stand-in.
    func prototype(_ name: String) async -> Entity? {
        if let p = prototypes[name] { return p }
        if missing.contains(name) { return nil }
        if let t = inFlight[name] { return await t.value }
        let task = Task<Entity?, Never> { [weak self] in
            guard let self, let url = self.url(for: name) else { return nil }
            do {
                let e = try await Entity(contentsOf: url)
                e.name = name
                return e
            } catch {
                NSLog("amux world: failed to load \(name): \(error)")
                return nil
            }
        }
        inFlight[name] = task
        let e = await task.value
        inFlight[name] = nil
        if let e { prototypes[name] = e } else { missing.insert(name) }
        return e
    }

    /// A fresh clone of a model, or nil so the caller can fall back.
    func instance(_ name: String) async -> Entity? {
        guard let p = await prototype(name) else { return nil }
        return p.clone(recursive: true)
    }
}

// MARK: - Primitive stand-ins
//
// Everything the scene needs, as boxes and spheres, in the same units and at
// the same anchors the real models use (origin at the base, Y up, facing -Z).
// Deliberately a little charming rather than placeholder-grey: the scene is
// usable like this and the user may well see it before the art lands.

enum WorldPrimitives {
    static func box(_ size: SIMD3<Float>, _ color: NSColor, roughness: Float = 0.9,
                    metallic: Bool = false, corner: Float = 0.01) -> ModelEntity {
        let mesh = MeshResource.generateBox(width: size.x, height: size.y, depth: size.z,
                                            cornerRadius: corner)
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.roughness = .init(floatLiteral: roughness)
        m.metallic = .init(floatLiteral: metallic ? 1 : 0)
        let e = ModelEntity(mesh: mesh, materials: [m])
        e.position.y = size.y / 2
        return e
    }

    static func emissive(_ size: SIMD3<Float>, _ color: NSColor, intensity: Float = 4) -> ModelEntity {
        let mesh = MeshResource.generateBox(width: size.x, height: size.y, depth: size.z)
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: .black)
        m.emissiveColor = .init(color: color)
        m.emissiveIntensity = intensity
        let e = ModelEntity(mesh: mesh, materials: [m])
        e.position.y = size.y / 2
        return e
    }

    static func sphere(_ radius: Float, _ color: NSColor, roughness: Float = 0.8) -> ModelEntity {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.roughness = .init(floatLiteral: roughness)
        return ModelEntity(mesh: .generateSphere(radius: radius), materials: [m])
    }

    static func plane(_ w: Float, _ d: Float, _ color: NSColor, roughness: Float = 0.95) -> ModelEntity {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.roughness = .init(floatLiteral: roughness)
        return ModelEntity(mesh: .generatePlane(width: w, depth: d), materials: [m])
    }

    static func unlitText(_ text: String, size: Float, color: NSColor, weight: NSFont.Weight = .semibold) -> ModelEntity {
        let font = NSFont.systemFont(ofSize: CGFloat(size), weight: weight)
        let mesh = MeshResource.generateText(text, extrusionDepth: size * 0.05, font: font,
                                             containerFrame: .zero, alignment: .center,
                                             lineBreakMode: .byClipping)
        let e = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
        // generateText anchors at the baseline's left; centre it
        let b = mesh.bounds
        e.position = SIMD3(-(b.min.x + b.max.x) / 2, -(b.min.y + b.max.y) / 2, 0)
        let holder = ModelEntity()
        holder.addChild(e)
        return holder
    }

    // -- room pieces --

    /// A desk with a monitor whose screen glows the given colour.
    static func desk(glow: NSColor) -> Entity {
        let root = Entity()
        let top = box(SIMD3(1.4, 0.04, 0.7), NSColor(white: 0.16, alpha: 1), roughness: 0.7)
        top.position.y = 0.74
        root.addChild(top)
        for x: Float in [-0.6, 0.6] {
            for z: Float in [-0.28, 0.28] {
                let leg = box(SIMD3(0.05, 0.72, 0.05), NSColor(white: 0.1, alpha: 1))
                leg.position = SIMD3(x, 0.36, z)
                root.addChild(leg)
            }
        }
        // monitor on the far edge, screen facing +Z (towards the chair)
        let stand = box(SIMD3(0.06, 0.16, 0.06), NSColor(white: 0.08, alpha: 1))
        stand.position = SIMD3(0, 0.84, -0.22)
        root.addChild(stand)
        let bezel = box(SIMD3(0.62, 0.38, 0.03), NSColor(white: 0.06, alpha: 1), roughness: 0.5)
        bezel.position = SIMD3(0, 1.11, -0.22)
        root.addChild(bezel)
        let screen = emissive(SIMD3(0.56, 0.32, 0.005), glow, intensity: 1.6)
        screen.name = "screen"
        screen.position = SIMD3(0, 1.11, -0.2)
        root.addChild(screen)
        let keyboard = box(SIMD3(0.42, 0.02, 0.14), NSColor(white: 0.09, alpha: 1))
        keyboard.position = SIMD3(0, 0.77, 0.08)
        root.addChild(keyboard)
        return root
    }

    static func chair() -> Entity {
        let root = Entity()
        let seat = box(SIMD3(0.48, 0.06, 0.48), NSColor(white: 0.12, alpha: 1), roughness: 0.6)
        seat.position.y = 0.45
        root.addChild(seat)
        let back = box(SIMD3(0.46, 0.5, 0.06), NSColor(white: 0.12, alpha: 1), roughness: 0.6)
        back.position = SIMD3(0, 0.73, 0.22)
        root.addChild(back)
        let post = box(SIMD3(0.06, 0.42, 0.06), NSColor(white: 0.2, alpha: 1), metallic: true)
        post.position.y = 0.21
        root.addChild(post)
        let base = box(SIMD3(0.5, 0.03, 0.5), NSColor(white: 0.18, alpha: 1), metallic: true, corner: 0.15)
        base.position.y = 0.015
        root.addChild(base)
        return root
    }

    /// A server rack: dark cabinet, a column of blinking-capable LEDs.
    static func serverRack() -> Entity {
        let root = Entity()
        let cab = box(SIMD3(0.6, 2.0, 0.8), NSColor(white: 0.07, alpha: 1), roughness: 0.6, metallic: true)
        root.addChild(cab)
        for i in 0..<9 {
            let led = emissive(SIMD3(0.04, 0.04, 0.01), i % 3 == 0 ? .systemOrange : .systemGreen, intensity: 3)
            led.name = "led\(i)"
            led.position = SIMD3(-0.2 + Float(i % 3) * 0.2, 0.3 + Float(i / 3) * 0.55, 0.405)
            root.addChild(led)
        }
        return root
    }

    static func couch() -> Entity {
        let root = Entity()
        let c = NSColor(red: 0.22, green: 0.2, blue: 0.19, alpha: 1)
        let seat = box(SIMD3(2.0, 0.42, 0.9), c, roughness: 1, corner: 0.06)
        root.addChild(seat)
        let back = box(SIMD3(2.0, 0.42, 0.24), c, roughness: 1, corner: 0.06)
        back.position = SIMD3(0, 0.63, -0.33)
        root.addChild(back)
        for x: Float in [-0.94, 0.94] {
            let arm = box(SIMD3(0.14, 0.6, 0.9), c, roughness: 1, corner: 0.05)
            arm.position = SIMD3(x, 0.3, 0)
            root.addChild(arm)
        }
        return root
    }

    static func mattress() -> Entity {
        let m = box(SIMD3(1.0, 0.18, 1.9), NSColor(white: 0.55, alpha: 1), roughness: 1, corner: 0.05)
        let root = Entity(); root.addChild(m)
        let blanket = box(SIMD3(0.9, 0.06, 1.1), NSColor(red: 0.2, green: 0.24, blue: 0.3, alpha: 1), roughness: 1, corner: 0.03)
        blanket.position = SIMD3(0, 0.18, 0.25)
        root.addChild(blanket)
        return root
    }

    static func whiteboard() -> Entity {
        let root = Entity()
        let board = box(SIMD3(1.8, 1.1, 0.03), NSColor(white: 0.82, alpha: 1), roughness: 0.4)
        board.position.y = 1.4
        root.addChild(board)
        let frame = box(SIMD3(1.86, 1.16, 0.02), NSColor(white: 0.25, alpha: 1), metallic: true)
        frame.position = SIMD3(0, 1.4, -0.01)
        root.addChild(frame)
        return root
    }

    static func neonSign(_ text: String, color: NSColor) -> Entity {
        let root = Entity()
        let t = unlitText(text, size: 0.42, color: color, weight: .bold)
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: .black)
        m.emissiveColor = .init(color: color)
        m.emissiveIntensity = 5
        if let me = t.children.first as? ModelEntity { me.model?.materials = [m] }
        root.addChild(t)
        return root
    }

    static func crt() -> Entity {
        let root = Entity()
        let body = box(SIMD3(0.44, 0.38, 0.42), NSColor(red: 0.78, green: 0.75, blue: 0.66, alpha: 1), roughness: 0.8, corner: 0.03)
        root.addChild(body)
        let screen = emissive(SIMD3(0.32, 0.26, 0.005), NSColor(red: 0.3, green: 1.0, blue: 0.45, alpha: 1), intensity: 1.2)
        screen.name = "screen"
        screen.position = SIMD3(0, 0.2, 0.213)
        root.addChild(screen)
        return root
    }

    static func pizzaBox() -> Entity {
        let root = Entity()
        let b = box(SIMD3(0.4, 0.05, 0.4), NSColor(red: 0.72, green: 0.55, blue: 0.35, alpha: 1), roughness: 1, corner: 0.01)
        root.addChild(b)
        return root
    }

    static func can(_ color: NSColor) -> Entity {
        let root = Entity()
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.roughness = .init(floatLiteral: 0.3)
        m.metallic = .init(floatLiteral: 0.8)
        let e = ModelEntity(mesh: .generateCylinder(height: 0.14, radius: 0.033), materials: [m])
        e.position.y = 0.07
        root.addChild(e)
        return root
    }

    static func cardboardBox(_ s: Float) -> Entity {
        let root = Entity()
        root.addChild(box(SIMD3(s, s * 0.8, s), NSColor(red: 0.62, green: 0.48, blue: 0.32, alpha: 1), roughness: 1, corner: 0.01))
        return root
    }

    static func arcadeCabinet() -> Entity {
        let root = Entity()
        let body = box(SIMD3(0.7, 1.8, 0.8), NSColor(red: 0.12, green: 0.1, blue: 0.16, alpha: 1), roughness: 0.6, corner: 0.02)
        root.addChild(body)
        let screen = emissive(SIMD3(0.5, 0.4, 0.005), NSColor(red: 1.0, green: 0.3, blue: 0.7, alpha: 1), intensity: 1.5)
        screen.name = "screen"
        screen.position = SIMD3(0, 1.25, 0.403)
        root.addChild(screen)
        let marquee = emissive(SIMD3(0.7, 0.18, 0.01), NSColor(red: 0.3, green: 0.9, blue: 1.0, alpha: 1), intensity: 2.5)
        marquee.position = SIMD3(0, 1.72, 0.405)
        root.addChild(marquee)
        return root
    }

    static func extinguisher() -> Entity {
        let root = Entity()
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: NSColor(red: 0.8, green: 0.12, blue: 0.12, alpha: 1))
        m.roughness = .init(floatLiteral: 0.4)
        let e = ModelEntity(mesh: .generateCylinder(height: 0.5, radius: 0.08), materials: [m])
        e.position.y = 0.25
        root.addChild(e)
        return root
    }

    /// A flat slab of any planar outline: `top` is the outline (any winding),
    /// extruded downward along its normal by `thickness`. Used for the roof,
    /// whose two pitched planes have to meet along a hip.
    static func prism(_ top: [SIMD3<Float>], thickness t: Float, color: NSColor, roughness: Float = 0.95) -> ModelEntity {
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        var n = simd_normalize(simd_cross(top[1] - top[0], top[2] - top[0]))
        var outline = top
        if n.y < 0 { outline.reverse(); n = -n }
        let bottom = outline.map { $0 - n * t }
        let centroid = outline.reduce(SIMD3<Float>(0, 0, 0), +) / Float(outline.count)
        func face(_ pts: [SIMD3<Float>], normal: SIMD3<Float>) {
            let base = UInt32(positions.count)
            positions += pts
            normals += Array(repeating: normal, count: pts.count)
            for i in 1..<(pts.count - 1) { indices += [base, base + UInt32(i), base + UInt32(i + 1)] }
        }
        face(outline, normal: n)
        face(bottom.reversed(), normal: -n)
        for i in 0..<outline.count {
            let j = (i + 1) % outline.count
            var side = [outline[i], bottom[i], bottom[j], outline[j]]
            var sn = simd_normalize(simd_cross(side[1] - side[0], side[2] - side[0]))
            let mid = (outline[i] + outline[j]) / 2
            if simd_dot(sn, mid - centroid) < 0 { side.reverse(); sn = -sn }
            face(side, normal: sn)
        }
        var d = MeshDescriptor()
        d.positions = MeshBuffers.Positions(positions)
        d.normals = MeshBuffers.Normals(normals)
        d.primitives = .triangles(indices)
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.roughness = .init(floatLiteral: roughness)
        m.faceCulling = .none
        let mesh = (try? MeshResource.generate(from: [d])) ?? .generateBox(size: 0.01)
        return ModelEntity(mesh: mesh, materials: [m])
    }

    /// A floor lamp: weighted base, thin pole, a drum shade that the daylight
    /// pass makes glow after dark, and a bulb where its light comes from.
    static func floorLamp(height: Float = 1.55) -> (lamp: Entity, shade: ModelEntity, bulbAt: SIMD3<Float>) {
        let root = Entity()
        let metal = NSColor(white: 0.12, alpha: 1)
        var mm = PhysicallyBasedMaterial()
        mm.baseColor = .init(tint: metal); mm.roughness = .init(floatLiteral: 0.45); mm.metallic = .init(floatLiteral: 1)
        let base = ModelEntity(mesh: .generateCylinder(height: 0.03, radius: 0.17), materials: [mm])
        base.position.y = 0.015
        root.addChild(base)
        let pole = box(SIMD3(0.025, height, 0.025), metal, roughness: 0.45, metallic: true, corner: 0)
        root.addChild(pole)
        var sm = PhysicallyBasedMaterial()
        sm.baseColor = .init(tint: NSColor(red: 0.92, green: 0.86, blue: 0.72, alpha: 1)); sm.roughness = .init(floatLiteral: 1)
        let shade = ModelEntity(mesh: .generateCylinder(height: 0.32, radius: 0.21), materials: [sm])
        shade.position.y = height + 0.08
        root.addChild(shade)
        return (root, shade, SIMD3(0, height + 0.02, 0))
    }

    static func bareBulb() -> Entity {
        let root = Entity()
        let cord = box(SIMD3(0.01, 0.6, 0.01), NSColor(white: 0.1, alpha: 1))
        cord.position.y = -0.3
        root.addChild(cord)
        let bulb = emissive(SIMD3(0.08, 0.12, 0.08), NSColor(red: 1.0, green: 0.85, blue: 0.6, alpha: 1), intensity: 6)
        bulb.position.y = -0.66
        root.addChild(bulb)
        return root
    }

    /// Minecraft proportions: 32 px tall, 1 px = this many metres.
    static let px: Float = 1.8 / 32
    static let figureHeight: Float = 32.6 * (1.8 / 32)
    static let figureHipHeight: Float = 12 * (1.8 / 32)

    /// A blocky figure in Minecraft proportions with the hood up: an 8 px cube
    /// head, an 8x12x4 torso, 4x12x4 limbs. The hoodie takes the agent's brand
    /// colour; the face, jeans and shoes are its own. Parts are named so the
    /// actor can pose them: `hips` carries everything and rises and falls,
    /// `legL`/`legR` pivot at the hip, `armL`/`armR` at the shoulder, `neck`
    /// turns the head. Every piece has its base at its parent pivot, so a
    /// rotation swings it the way a limb swings.
    static func figure(hoodie: NSColor, seed: Int = 0) -> Entity {
        func P(_ n: Float) -> Float { n * px }
        let skins = [
            NSColor(red: 0.96, green: 0.80, blue: 0.69, alpha: 1),
            NSColor(red: 0.87, green: 0.66, blue: 0.52, alpha: 1),
            NSColor(red: 0.64, green: 0.44, blue: 0.31, alpha: 1),
            NSColor(red: 0.42, green: 0.28, blue: 0.19, alpha: 1),
        ]
        let skin = skins[abs(seed) % skins.count]
        let jeans = NSColor(red: 0.17, green: 0.21, blue: 0.33, alpha: 1)
        let shoe = NSColor(white: 0.09, alpha: 1)
        let hoodShade = hoodie.blended(withFraction: 0.28, of: .black) ?? hoodie
        let string = NSColor(white: 0.92, alpha: 1)
        let eye = NSColor(red: 0.09, green: 0.1, blue: 0.16, alpha: 1)

        func block(_ w: Float, _ h: Float, _ d: Float, _ c: NSColor, x: Float = 0, base: Float = 0, z: Float = 0) -> ModelEntity {
            let e = box(SIMD3(P(w), P(h), P(d)), c, roughness: 1, corner: 0)
            e.position += SIMD3(P(x), P(base), P(z))
            return e
        }

        let root = Entity()
        let hips = Entity(); hips.name = "hips"; hips.position.y = P(12)
        root.addChild(hips)

        // legs hang from the hip; jeans with a dark shoe at the bottom
        for (name, x) in [("legL", Float(-2)), ("legR", Float(2))] {
            let pivot = Entity(); pivot.name = name; pivot.position = SIMD3(P(x), 0, 0)
            pivot.addChild(block(4, 10, 4, jeans, base: -10))
            pivot.addChild(block(4, 2, 4, shoe, base: -12))
            hips.addChild(pivot)
        }

        // torso, kangaroo pocket, drawstrings
        let torso = block(8, 12, 4, hoodie); torso.name = "torso"
        hips.addChild(torso)
        hips.addChild(block(6, 3, 0.5, hoodShade, base: 2, z: 2.2))
        hips.addChild(block(0.5, 3, 0.4, string, x: -1.2, base: 8.5, z: 2.2))
        hips.addChild(block(0.5, 3, 0.4, string, x: 1.2, base: 8.5, z: 2.2))

        // arms hang from the shoulder; sleeve then hand
        for (name, x) in [("armL", Float(-6)), ("armR", Float(6))] {
            let pivot = Entity(); pivot.name = name; pivot.position = SIMD3(P(x), P(11), 0)
            pivot.addChild(block(4, 10, 4, hoodie, base: -10))
            pivot.addChild(block(4, 2, 4, skin, base: -12))
            hips.addChild(pivot)
        }

        // head: the hood is the cube, a little larger than a bare head, with
        // the face set into its front and the hood's rim shading it
        let neck = Entity(); neck.name = "neck"; neck.position.y = P(12)
        hips.addChild(neck)
        let hood = block(8.6, 8.6, 8.6, hoodie); hood.name = "head"
        neck.addChild(hood)
        neck.addChild(block(6.2, 6.6, 0.4, hoodShade, base: 1.0, z: 4.15))     // shadow inside the hood
        neck.addChild(block(5.6, 6.0, 0.4, skin, base: 1.3, z: 4.35))          // face
        neck.addChild(block(1.3, 1.3, 0.3, eye, x: -1.5, base: 4.4, z: 4.6))
        neck.addChild(block(1.3, 1.3, 0.3, eye, x: 1.5, base: 4.4, z: 4.6))
        neck.addChild(block(0.5, 0.5, 0.3, .white, x: -1.2, base: 5.0, z: 4.7)) // catchlights
        neck.addChild(block(0.5, 0.5, 0.3, .white, x: 1.8, base: 5.0, z: 4.7))
        return root
    }
}
