import RealityKit
import AppKit
import simd

// MARK: - The den
//
// A converted back room at the top of a building: concrete floor, brick and
// plaster walls, the roof cut away so the camera looks in. Two walls are built,
// the two facing the camera are left out, like the reference. Everything is
// placed from one layout so the choreography (where the door is, where each
// agent sits, the path between) and the dressing agree.
//
// Units are metres. Y is up. A model's origin is at its base and it faces -Z.
// Models come from WorldAssets, converted from CC0 packs; each has a primitive
// stand-in so the room is whole with or without them.

struct WorldSeat {
    enum Kind { case desk, couch, floor }
    let kind: Kind
    /// Where the figure's origin goes when seated.
    let position: SIMD3<Float>
    /// Radians about Y; 0 faces +Z.
    let yaw: Float
    /// A spot to stand next to the seat, on the way in and out.
    let approach: SIMD3<Float>
    /// The desk's screen, if any, for tinting by agent brand.
    weak var screen: ModelEntity?
}

struct WorldLayout {
    var seats: [WorldSeat] = []
    /// Just outside the door, where new agents appear.
    var spawn = SIMD3<Float>(3.0, 0, -6.4)
    /// Just inside the door.
    var threshold = SIMD3<Float>(3.0, 0, -4.0)
    /// The middle of the floor, for the camera to look at.
    var focus = SIMD3<Float>(0, 0.6, -0.6)
    /// Where a figure with nowhere to sit can lean.
    var standing: [SIMD3<Float>] = [SIMD3(1.0, 0, 2.6), SIMD3(-2.4, 0, 2.2), SIMD3(-1.0, 0, 3.4)]
    /// The door leaf, for swinging when someone passes.
    weak var door: Entity?
}

@MainActor
enum WorldRoom {
    static let floorW: Float = 12
    static let floorD: Float = 10
    static let wallH: Float = 2.4
    static let ceiling: Float = 2.9

    static let concrete = NSColor(red: 0.2, green: 0.2, blue: 0.21, alpha: 1)
    static let brick = NSColor(red: 0.34, green: 0.2, blue: 0.16, alpha: 1)
    static let plaster = NSColor(red: 0.3, green: 0.3, blue: 0.29, alpha: 1)
    static let neon = NSColor(red: 1.0, green: 0.25, blue: 0.55, alpha: 1)
    static let screenGreen = NSColor(red: 0.3, green: 0.95, blue: 0.5, alpha: 1)
    static let cityGlow = NSColor(red: 0.16, green: 0.24, blue: 0.4, alpha: 1)
    static let warm = NSColor(red: 1.0, green: 0.82, blue: 0.6, alpha: 1)

    /// Builds the room under `root`, returning the layout the choreography uses.
    static func build(under root: Entity) async -> WorldLayout {
        var layout = WorldLayout()
        let assets = WorldAssets.shared
        let quarter: Float = .pi / 2

        @discardableResult
        func place(_ name: String, at p: SIMD3<Float>, yaw: Float = 0, scale: Float = 1,
                   under parent: Entity? = nil, fallback: (() -> Entity)? = nil) async -> Entity {
            let e = await assets.instance(name) ?? fallback?() ?? Entity()
            e.name = name
            e.position = p
            e.orientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
            if scale != 1 { e.scale = SIMD3(repeating: scale) }
            (parent ?? root).addChild(e)
            return e
        }
        func light(_ p: SIMD3<Float>, _ color: NSColor, _ lux: Float, radius: Float) {
            let l = PointLight()
            l.light.color = color
            l.light.intensity = lux
            l.light.attenuationRadius = radius
            l.position = p
            root.addChild(l)
        }

        // -- floor: one slab; thirty tiles looked the same and cost thirty draws --
        root.addChild(WorldPrimitives.plane(floorW, floorD, concrete))
        // the building under it
        let slab = WorldPrimitives.box(SIMD3(floorW + 0.8, 1.2, floorD + 0.8), NSColor(white: 0.14, alpha: 1))
        slab.position.y = -1.3
        root.addChild(slab)

        // -- back wall along x at z = -5: brick, with the doorway at x = 3 --
        // Kenney wall pieces run along their local z, so they turn a quarter here.
        let hasWalls = await assets.prototype("wall") != nil
        for x in stride(from: -5, through: 5, by: 2) {
            if hasWalls {
                await place(x == 3 ? "wall_doorway" : "wall", at: SIMD3(Float(x), 0, -floorD / 2), yaw: quarter)
            } else {
                let seg = WorldPrimitives.box(SIMD3(2, wallH, 0.2), brick, roughness: 1)
                seg.position = SIMD3(Float(x), 0, -floorD / 2)
                if x == 3 { seg.position.y = 2.1; seg.scale.y = 0.15 }
                root.addChild(seg)
            }
        }
        // the door, hinged on the doorway's left post, swung into the room
        let door = await place("door", at: SIMD3(2.55, 0, -floorD / 2 + 0.05), yaw: quarter, fallback: {
            let leaf = WorldPrimitives.box(SIMD3(0.06, 2.1, 0.9), NSColor(red: 0.28, green: 0.2, blue: 0.14, alpha: 1))
            leaf.position.z = 0.45
            let h = Entity(); h.addChild(leaf); return h
        })
        let leaf = door.findEntity(named: "door") ?? door
        leaf.orientation = simd_quatf(angle: 1.7, axis: SIMD3(0, 1, 0))
        layout.door = leaf
        light(SIMD3(3.0, 2.0, -6.2), warm, 2200, radius: 4.5)

        // -- left wall along z at x = -6: plaster, two windows onto the city --
        for z in stride(from: -4, through: 4, by: 2) {
            let window = (z == -2 || z == 2)
            if hasWalls {
                await place(window ? "wall_window" : "wall_plaster", at: SIMD3(-floorW / 2, 0, Float(z)))
            } else {
                let seg = WorldPrimitives.box(SIMD3(0.2, wallH, 2), plaster, roughness: 1)
                seg.position = SIMD3(-floorW / 2, 0, Float(z))
                root.addChild(seg)
            }
            if window {
                // the city outside the glass, and its cold spill across the floor
                let glass = WorldPrimitives.emissive(SIMD3(0.04, 1.4, 1.2), cityGlow, intensity: 1.2)
                glass.position = SIMD3(-floorW / 2 - 0.12, 0.85, Float(z))
                root.addChild(glass)
                let spill = SpotLight()
                spill.light.color = cityGlow
                spill.light.intensity = 5000
                spill.light.innerAngleInDegrees = 35
                spill.light.outerAngleInDegrees = 70
                spill.light.attenuationRadius = 7
                spill.position = SIMD3(-floorW / 2 - 0.3, 2.2, Float(z))
                spill.look(at: SIMD3(-2, 0, Float(z)), from: spill.position, relativeTo: nil)
                root.addChild(spill)
            }
        }
        await place("column", at: SIMD3(-floorW / 2, 0, -floorD / 2))
        await place("column", at: SIMD3(-floorW / 2, 0, floorD / 2))
        await place("column", at: SIMD3(floorW / 2, 0, -floorD / 2))

        // -- workstations: two rows of four, facing the back wall --
        let xs: [Float] = [-4.2, -1.9, 0.4, 2.7]
        for (row, z) in [(0, Float(-3.3)), (1, Float(-0.7))] {
            for (i, x) in xs.enumerated() {
                let desk = await place("desk", at: SIMD3(x, 0, z), fallback: { WorldPrimitives.desk(glow: screenGreen) })
                let deskTop: Float = 0.78
                var screen = desk.findEntity(named: "screen") as? ModelEntity
                if screen == nil {
                    // a real desk: give it a monitor, keyboard and mouse, and a
                    // screen that glows the agent's colour
                    await place("monitor", at: SIMD3(x, deskTop, z - 0.14))
                    await place("keyboard", at: SIMD3(x, deskTop, z + 0.2))
                    await place("mouse", at: SIMD3(x + 0.42, deskTop, z + 0.2))
                    let s = WorldPrimitives.emissive(SIMD3(0.5, 0.32, 0.006), screenGreen, intensity: 1.6)
                    s.name = "screen"
                    s.position = SIMD3(x, deskTop + 0.12, z - 0.14 + 0.085)
                    root.addChild(s)
                    screen = s
                }
                let chairPos = SIMD3(x, 0, z + 0.78)
                await place("chair", at: chairPos, yaw: .pi, fallback: WorldPrimitives.chair)
                layout.seats.append(WorldSeat(
                    kind: .desk, position: chairPos, yaw: .pi,
                    approach: SIMD3(x, 0, z + 1.5), screen: screen))
                light(SIMD3(x, 1.1, z + 0.2), NSColor(red: 0.5, green: 0.95, blue: 0.85, alpha: 1), 320, radius: 1.7)
                // clutter, varied per desk
                switch (row * 4 + i) % 4 {
                case 0: await place("can", at: SIMD3(x + 0.55, deskTop, z + 0.05), fallback: { WorldPrimitives.can(.systemRed) })
                case 1: await place("mug", at: SIMD3(x - 0.55, deskTop, z + 0.1), yaw: 0.6)
                case 2: await place("headphones", at: SIMD3(x - 0.5, deskTop, z - 0.05), yaw: -0.4)
                default: await place("styrofoam", at: SIMD3(x + 0.55, deskTop, z - 0.1), yaw: 0.3)
                }
            }
        }

        // -- light over the rows: pendants on their cords --
        for (x, z) in [(Float(-3.0), Float(-2.0)), (1.5, -2.0), (3.5, 2.6)] {
            await place("pendant", at: SIMD3(x, ceiling, z), fallback: WorldPrimitives.bareBulb)
            light(SIMD3(x, ceiling - 0.6, z), warm, 6500, radius: 8)
        }

        // -- infrastructure along the back-left --
        let rack0 = await place("server_rack", at: SIMD3(-4.7, 0, -4.55), fallback: WorldPrimitives.serverRack)
        rack0.name = "rack0"
        let rack1 = await place("server_tower", at: SIMD3(-3.35, 0, -4.6), fallback: WorldPrimitives.serverRack)
        rack1.name = "rack1"
        await place("router", at: SIMD3(-3.35, 2.08, -4.6), scale: 0.4)
        light(SIMD3(-4.2, 1.4, -3.9), screenGreen, 500, radius: 2.5)
        // cables down the wall from the racks, and across the floor to the desks
        for (i, x) in [Float(-2.1), -0.6, 1.9, 4.6].enumerated() {
            await place("cable", at: SIMD3(x, wallH, -floorD / 2 + 0.12), yaw: Float(i) * 0.7, fallback: {
                let c = WorldPrimitives.box(SIMD3(0.03, 2.4, 0.03), NSColor(white: 0.05, alpha: 1)); c.position.y = -1.2
                let h = Entity(); h.addChild(c); return h
            })
        }
        for (i, x) in xs.enumerated() {
            await place("cables_droop", at: SIMD3(x + 0.6, 0.01, -4.3), yaw: quarter + Float(i % 2) * 0.2, scale: 1.4, fallback: {
                let c = WorldPrimitives.box(SIMD3(0.03, 0.02, 1.2), NSColor(white: 0.05, alpha: 1)); let h = Entity(); h.addChild(c); return h
            })
        }
        await place("pipe_detail", at: SIMD3(5.6, 0, -4.6), scale: 1.5)

        // -- walls' dressing --
        await place("whiteboard", at: SIMD3(0.6, 0, -floorD / 2 + 0.07), fallback: WorldPrimitives.whiteboard)
        let sign = await place("neon", at: SIMD3(-2.4, 2.0, -floorD / 2 + 0.1), fallback: { WorldPrimitives.neonSign("amux", color: neon) })
        sign.name = "neon"
        light(SIMD3(-2.4, 2.0, -floorD / 2 + 0.7), neon, 2400, radius: 4.5)
        await place("neon_sign", at: SIMD3(-floorW / 2 + 0.08, 1.6, 3.6), yaw: quarter)
        light(SIMD3(-floorW / 2 + 0.6, 1.7, 3.6), neon, 900, radius: 3)
        await place("coat_rack", at: SIMD3(4.9, 0, -4.4), scale: 2.2)
        await place("extinguisher", at: SIMD3(5.6, 0, -3.6), fallback: WorldPrimitives.extinguisher)

        // -- the corner the crew actually lives in --
        await place("couch", at: SIMD3(3.6, 0, 3.0), yaw: .pi, fallback: WorldPrimitives.couch)
        layout.seats.append(WorldSeat(kind: .couch, position: SIMD3(3.1, 0.02, 3.0), yaw: .pi, approach: SIMD3(3.1, 0, 2.0)))
        layout.seats.append(WorldSeat(kind: .couch, position: SIMD3(4.1, 0.02, 3.0), yaw: .pi, approach: SIMD3(4.1, 0, 2.0)))
        let pallet = await place("pallet", at: SIMD3(-4.6, 0, 3.4), yaw: 0.15, fallback: WorldPrimitives.mattress)
        if await assets.prototype("pallet") != nil {
            let m = WorldPrimitives.box(SIMD3(1.5, 0.18, 0.95), NSColor(white: 0.55, alpha: 1), roughness: 1, corner: 0.05)
            m.position = SIMD3(0, 0.19, 0)
            pallet.addChild(m)
            let blanket = WorldPrimitives.box(SIMD3(1.0, 0.06, 0.8), NSColor(red: 0.2, green: 0.24, blue: 0.3, alpha: 1), roughness: 1, corner: 0.03)
            blanket.position = SIMD3(-0.15, 0.37, 0.05)
            pallet.addChild(blanket)
            await place("pillow", at: SIMD3(0.55, 0.37, 0), yaw: 0.3, under: pallet)
        }
        await place("shelf", at: SIMD3(-5.55, 0, -0.6), yaw: quarter)
        await place("boxes", at: SIMD3(-5.4, 0, 1.0), yaw: 0.4)
        await place("arcade", at: SIMD3(-5.3, 0, 1.9), yaw: quarter, fallback: WorldPrimitives.arcadeCabinet)
        light(SIMD3(-4.6, 1.3, 1.9), NSColor(red: 1.0, green: 0.4, blue: 0.75, alpha: 1), 600, radius: 2.5)
        await place("fridge", at: SIMD3(5.3, 0, -1.6), yaw: -quarter)
        let crate = await place("crate", at: SIMD3(1.4, 0, 3.6), yaw: 0.2, fallback: { WorldPrimitives.cardboardBox(0.6) })
        await place("crt", at: SIMD3(0, 0.65, 0), yaw: -0.6, under: crate, fallback: WorldPrimitives.crt)
        for (i, p) in [SIMD3<Float>(4.7, 0, 1.5), SIMD3(4.72, 0.06, 1.52)].enumerated() {
            await place("pizza_box", at: p, yaw: Float(i) * 0.3, fallback: WorldPrimitives.pizzaBox)
        }
        await place("can_crushed", at: SIMD3(2.4, 0, 2.2), yaw: 1.1)
        await place("can_crushed", at: SIMD3(4.3, 0, 3.9), yaw: 0.3)
        await place("papers", at: SIMD3(0.4, 0.005, 2.4), yaw: 0.5)
        await place("papers", at: SIMD3(-2.6, 0.005, 1.4), yaw: -1.2)
        await place("skateboard", at: SIMD3(2.3, 0, 4.0), yaw: 0.5)
        await place("trash_bags", at: SIMD3(5.4, 0, 0.6), yaw: 0.8)
        await place("cup", at: SIMD3(2.9, 0.02, 2.3), yaw: 0.2)

        // -- outside: the city, below the roofline and far enough to be skyline --
        let ground = WorldPrimitives.plane(160, 160, NSColor(white: 0.05, alpha: 1))
        ground.position.y = -10
        root.addChild(ground)
        var seed: UInt32 = 7
        func rnd() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(seed >> 8) / Float(1 << 24) }
        // neighbouring rooftops: low blocks with lit windows
        for i in 0..<14 {
            let angle = Float(i) / 14 * 2 * .pi + rnd() * 0.25
            let r: Float = 16 + rnd() * 12
            let w = 4 + rnd() * 5, h = 2 + rnd() * 5, d = 4 + rnd() * 5
            let b = WorldPrimitives.box(SIMD3(w, h, d), NSColor(white: CGFloat(0.16 + rnd() * 0.08), alpha: 1), roughness: 1)
            b.position = SIMD3(cos(angle) * r, -10 + h / 2, sin(angle) * r)
            root.addChild(b)
            for _ in 0..<(1 + Int(rnd() * 4)) {
                let win = WorldPrimitives.emissive(SIMD3(0.5, 0.5, 0.02), rnd() > 0.65 ? warm : cityGlow, intensity: 2.5)
                win.position = SIMD3((rnd() - 0.5) * w * 0.8, -h / 2 + 0.6 + rnd() * (h - 1.2), d / 2 + 0.01)
                b.addChild(win)
            }
        }
        // rooftop furniture on the nearest neighbours
        await place("tv_tower", at: SIMD3(-15, -5.5, -9), scale: 2.2)
        await place("antenna", at: SIMD3(-11, -6, -14), scale: 2)
        await place("ac_stacked", at: SIMD3(-13, -5.5, 4), scale: 1.6)
        await place("ac_unit", at: SIMD3(6, -5.5, -14), scale: 1.8)
        // the skyline: tall towers well back, rising past the horizon
        let towers = ["skyscraper_a", "skyscraper_b", "skyscraper_c", "skyscraper_d", "skyscraper_e", "building_low", "building_wide"]
        for i in 0..<7 {
            let angle = Float(i) / 7 * 2 * .pi + rnd() * 0.3
            let r: Float = 48 + rnd() * 30
            let t = await place(towers[i % towers.count], at: SIMD3(cos(angle) * r, -40 - rnd() * 8, sin(angle) * r),
                                yaw: rnd() * 6.28, fallback: { WorldPrimitives.box(SIMD3(10, 40, 10), NSColor(white: 0.08, alpha: 1)) })
            for _ in 0..<(3 + Int(rnd() * 4)) {
                let win = WorldPrimitives.emissive(SIMD3(0.9, 1.2, 0.05), rnd() > 0.6 ? warm : cityGlow, intensity: 3)
                win.position = SIMD3((rnd() - 0.5) * 8, 6 + rnd() * 36, 6.9)
                win.orientation = simd_quatf(angle: rnd() * 6.28, axis: SIMD3(0, 1, 0))
                t.addChild(win)
            }
        }

        // -- light --
        let moon = DirectionalLight()
        moon.light.color = NSColor(red: 0.55, green: 0.65, blue: 0.95, alpha: 1)
        moon.light.intensity = 4200
        moon.shadow = DirectionalLightComponent.Shadow(maximumDistance: 30, depthBias: 2)
        moon.look(at: SIMD3(0, 0, 0), from: SIMD3(-8, 14, 6), relativeTo: nil)
        root.addChild(moon)
        // a soft fill from the camera's side so the walls and floor read as
        // surfaces; the pools of warm light do the rest
        let fill = DirectionalLight()
        fill.light.color = NSColor(red: 0.6, green: 0.66, blue: 0.82, alpha: 1)
        fill.light.intensity = 1100
        fill.look(at: SIMD3(0, 0, 0), from: SIMD3(9, 9, 9), relativeTo: nil)
        root.addChild(fill)

        layout.focus = SIMD3(0, 0.6, -0.6)
        return layout
    }

    /// A blue-grey gradient sky for image-based lighting and the backdrop:
    /// enough fill that unlit surfaces read as surfaces, cool so the warm bulbs
    /// and screens pop.
    static func environment() async -> EnvironmentResource? {
        let w = 512, h = 256
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [
            CGColor(red: 0.20, green: 0.24, blue: 0.42, alpha: 1),   // zenith
            CGColor(red: 0.09, green: 0.10, blue: 0.17, alpha: 1),   // horizon
            CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1),   // ground
        ] as CFArray
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) else { return nil }
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: 0, y: 0), options: [])
        guard let img = ctx.makeImage() else { return nil }
        do {
            return try await EnvironmentResource(equirectangular: img)
        } catch {
            NSLog("amux world: environment resource failed: \(error)")
            return nil
        }
    }
}
