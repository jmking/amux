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

    /// The single animation carried by a clip file. Blender's USD exporter
    /// writes one clip per file, so a character's clips are separate USDZs
    /// (character_walk, character_wave, ...) whose skeleton matches the model's;
    /// RealityKit binds them by joint name when played on the model.
    func clip(_ name: String) async -> AnimationResource? {
        guard let p = await prototype(name) else { return nil }
        var found: AnimationResource?
        func walk(_ e: Entity) {
            if found == nil, let a = e.availableAnimations.first { found = a }
            for c in e.children where found == nil { walk(c) }
        }
        walk(p)
        return found
    }

    /// Every clip the character has, keyed by our own names.
    func characterClips() async -> [String: AnimationResource] {
        var out: [String: AnimationResource] = [:]
        for (key, file) in [("idle", "character"), ("walk", "character_walk"), ("wave", "character_wave"),
                            ("hit", "character_hit"), ("idle2", "character_idle2"), ("interact", "character_interact")] {
            if let c = await clip(file) { out[key] = c }
        }
        return out
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

    /// A hooded low-poly figure from primitives. Child names are what the
    /// procedural animations drive, so a real rigged model must expose the same
    /// names or its own clips.
    static func figure(hoodie: NSColor) -> Entity {
        let root = Entity()
        let skin = NSColor(red: 0.85, green: 0.7, blue: 0.58, alpha: 1)
        let dark = NSColor(white: 0.1, alpha: 1)

        let hips = Entity(); hips.name = "hips"; hips.position.y = 0.92
        root.addChild(hips)

        for (name, x) in [("legL", Float(-0.11)), ("legR", Float(0.11))] {
            let pivot = Entity(); pivot.name = name; pivot.position = SIMD3(x, 0, 0)
            let leg = box(SIMD3(0.16, 0.86, 0.18), dark, corner: 0.03)
            leg.position.y = -0.43
            pivot.addChild(leg)
            hips.addChild(pivot)
        }

        let torso = box(SIMD3(0.46, 0.62, 0.3), hoodie, roughness: 1, corner: 0.05)
        torso.name = "torso"
        torso.position.y = 0.31
        hips.addChild(torso)
        let pocket = box(SIMD3(0.3, 0.14, 0.02), hoodie.shadow(withLevel: 0.15) ?? hoodie, roughness: 1)
        pocket.position = SIMD3(0, 0.18, 0.16)
        hips.addChild(pocket)

        for (name, x) in [("armL", Float(-0.3)), ("armR", Float(0.3))] {
            let pivot = Entity(); pivot.name = name; pivot.position = SIMD3(x, 0.56, 0)
            let arm = box(SIMD3(0.13, 0.6, 0.15), hoodie, roughness: 1, corner: 0.03)
            arm.position.y = -0.3
            pivot.addChild(arm)
            let hand = sphere(0.06, skin)
            hand.position.y = -0.62
            pivot.addChild(hand)
            hips.addChild(pivot)
        }

        let neck = Entity(); neck.name = "neck"; neck.position.y = 0.64
        hips.addChild(neck)
        let head = sphere(0.17, skin)
        head.name = "head"
        head.position.y = 0.16
        neck.addChild(head)
        // hood: a hoodie-coloured shell open at the face
        let hood = box(SIMD3(0.4, 0.42, 0.38), hoodie, roughness: 1, corner: 0.14)
        hood.position = SIMD3(0, 0.17, -0.05)
        neck.addChild(hood)
        let face = box(SIMD3(0.26, 0.24, 0.02), NSColor(white: 0.02, alpha: 1))
        face.position = SIMD3(0, 0.16, 0.17)
        neck.addChild(face)
        return root
    }
}
