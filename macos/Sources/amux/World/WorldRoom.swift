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
    var focus = SIMD3<Float>(1, 0.6, 0.4)
    /// Where a figure with nowhere to sit can lean.
    var standing: [SIMD3<Float>] = WorldRoom.Den.standing.map { SIMD3($0.x, 0, $0.z) }
    /// The wall clock, redrawn by the scene as the minute changes.
    var clock: WorldClock?
    /// Where an agent stands to hang a coat on the way in, and the hooks.
    var rackApproach = SIMD3<Float>(WorldRoom.Den.coatRack.x - 0.55, 0, WorldRoom.Den.coatRack.z + 0.8)
    var rackHooks: [SIMD3<Float>] = (0..<6).map { i in
        let a = Float(i) / 6 * 2 * .pi + 0.3
        return SIMD3(WorldRoom.Den.coatRack.x + sin(a) * 0.27, 1.42, WorldRoom.Den.coatRack.z + cos(a) * 0.27)
    }
    /// The door leaf, for swinging when someone passes.
    weak var door: Entity?
    /// The amber beacon in the lane, blinked by the scene after dark.
    var blinker: (light: PointLight, face: ModelEntity)?
}

@MainActor
enum WorldRoom {
    /// The floor: the back wall stays on z = -5 and the window wall on x = -6,
    /// and the room runs out toward the open sides.
    static let minX: Float = -6, maxX: Float = 8
    static let minZ: Float = -5, maxZ: Float = 7
    static let floorW: Float = maxX - minX
    static let floorD: Float = maxZ - minZ
    static let center = SIMD3<Float>((minX + maxX) / 2, 0, (minZ + maxZ) / 2)
    /// The kit's wall tiles are 2.4 m; the walls carry on above them with a
    /// plain course in the same colour so the room reads as a proper room from
    /// the camera's height.
    static let tileH: Float = 2.4
    static let wallH: Float = 3.6
    static let ceiling: Float = 2.9

    /// Where things stand. Desk yaw 0 has the agent facing the back wall (-z),
    /// pi/2 facing the windows, pi facing the camera. Clusters rather than
    /// rows: a facing pair by the racks, an L in the back-right, a fan of
    /// three in the middle, one desk turned to the window, and the lounge in
    /// the foreground where it stays low.
    enum Den {
        static let desks: [(x: Float, z: Float, yaw: Float)] = [
            (-3.2, -2.25, .pi), (-3.2, -1.55, 0),                     // the pair
            (5.4, -3.0, 0), (6.6, -1.2, -.pi / 2),                    // the L
            (0.2, 1.3, 0.35), (2.6, 0.2, .pi), (4.6, 1.9, -0.45),      // the fan
            (-4.5, 2.0, .pi / 2),                                     // the window desk
        ]
        static let couch: (x: Float, z: Float, yaw: Float) = (4.8, 5.0, .pi)
        static let table: (x: Float, z: Float, yaw: Float) = (4.7, 3.75, 0.2)
        static let rug: (x: Float, z: Float, w: Float, d: Float) = (2.9, 3.3, 5.6, 3.4)
        static let lamps: [(x: Float, z: Float, yaw: Float)] = [(6.7, 5.9, 0.3), (-3.5, 6.1, -0.4)]
        static let bed: (x: Float, z: Float, yaw: Float) = (-4.7, 5.6, 0.15)
        static let arcade: (x: Float, z: Float, yaw: Float) = (-5.3, 4.2, .pi / 2)
        static let shelf: (x: Float, z: Float, yaw: Float) = (-5.55, -0.6, .pi / 2)
        static let fridge: (x: Float, z: Float, yaw: Float) = (7.4, -4.55, 0)
        static let coatRack: (x: Float, z: Float) = (4.2, -4.5)
        static let crate: (x: Float, z: Float, yaw: Float) = (0.6, 5.7, 0.2)
        static let standing: [(x: Float, z: Float)] = [(0.8, 4.6), (-1.6, 4.0), (1.8, 6.0)]
    }

    static let concrete = NSColor(red: 0.2, green: 0.2, blue: 0.21, alpha: 1)
    static let brick = NSColor(red: 0.34, green: 0.2, blue: 0.16, alpha: 1)
    static let plaster = NSColor(red: 0.3, green: 0.3, blue: 0.29, alpha: 1)
    static let neon = NSColor(red: 1.0, green: 0.25, blue: 0.55, alpha: 1)
    static let screenGreen = NSColor(red: 0.3, green: 0.95, blue: 0.5, alpha: 1)
    static let cityGlow = NSColor(red: 0.16, green: 0.24, blue: 0.4, alpha: 1)
    static let warm = NSColor(red: 1.0, green: 0.82, blue: 0.6, alpha: 1)

    /// Builds the room under `root`, returning the layout the choreography uses.
    static func build(under root: Entity, daylight: WorldDaylight) async -> WorldLayout {
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
        @discardableResult
        func light(_ p: SIMD3<Float>, _ color: NSColor, _ lux: Float, radius: Float) -> PointLight {
            let l = PointLight()
            l.light.color = color
            l.light.intensity = lux
            l.light.attenuationRadius = radius
            l.position = p
            root.addChild(l)
            return l
        }

        // -- floor: one slab; thirty tiles looked the same and cost thirty draws --
        let floor = WorldPrimitives.plane(floorW, floorD, concrete)
        floor.position = center
        root.addChild(floor)
        // a concrete plinth the room sits on, a step above the yard
        let slab = WorldPrimitives.box(SIMD3(floorW + 0.5, 0.12, floorD + 0.5), NSColor(white: 0.24, alpha: 1))
        slab.position = center + SIMD3(0, -0.12, 0)
        root.addChild(slab)

        // -- back wall along x at z = -5: brick, with the doorway at x = 3 --
        // Kenney wall pieces run along their local z, so they turn a quarter here.
        let hasWalls = await assets.prototype("wall") != nil
        for x in stride(from: Int(minX) + 1, through: Int(maxX) - 1, by: 2) {
            if hasWalls {
                await place(x == 3 ? "wall_doorway" : "wall", at: SIMD3(Float(x), 0, minZ), yaw: quarter)
                let course = WorldPrimitives.box(SIMD3(2, wallH - tileH, x == 3 ? 0.2 : 0.1), brick, roughness: 1, corner: 0)
                course.position = SIMD3(Float(x), tileH + (wallH - tileH) / 2, minZ)
                root.addChild(course)
            } else {
                let seg = WorldPrimitives.box(SIMD3(2, wallH, 0.2), brick, roughness: 1)
                seg.position = SIMD3(Float(x), wallH / 2, minZ)
                if x == 3 { seg.position.y = 2.1 + (wallH - 2.1) / 2; seg.scale.y = (wallH - 2.1) / wallH }   // the lintel
                root.addChild(seg)
            }
        }
        // the door, hinged on the doorway's left post, swung into the room
        let door = await place("door", at: SIMD3(2.55, 0, minZ + 0.05), yaw: quarter, fallback: {
            let leaf = WorldPrimitives.box(SIMD3(0.06, 2.1, 0.9), NSColor(red: 0.28, green: 0.2, blue: 0.14, alpha: 1))
            leaf.position.z = 0.45
            let h = Entity(); h.addChild(leaf); return h
        })
        let leaf = door.findEntity(named: "door") ?? door
        leaf.orientation = simd_quatf(angle: 1.7, axis: SIMD3(0, 1, 0))
        layout.door = leaf
        daylight.addLamp(light(SIMD3(3.0, 2.0, -6.2), warm, 8000, radius: 5))

        // -- left wall along z at x = -6: plaster, two windows onto the city --
        for z in stride(from: Int(minZ) + 1, through: Int(maxZ) - 1, by: 2) {
            let window = (z == -2 || z == 2)
            if hasWalls {
                await place(window ? "wall_window" : "wall_plaster", at: SIMD3(minX, 0, Float(z)))
                let course = WorldPrimitives.box(SIMD3(window ? 0.2 : 0.1, wallH - tileH, 2), plaster, roughness: 1, corner: 0)
                course.position = SIMD3(minX, tileH + (wallH - tileH) / 2, Float(z))
                root.addChild(course)
            } else {
                let seg = WorldPrimitives.box(SIMD3(0.2, wallH, 2), plaster, roughness: 1)
                seg.position = SIMD3(minX, wallH / 2, Float(z))
                root.addChild(seg)
            }
            if window {
                // glass you can see through, and the yard's cold spill across the floor at night
                var gm = PhysicallyBasedMaterial()
                gm.baseColor = .init(tint: NSColor(red: 0.75, green: 0.85, blue: 0.95, alpha: 1))
                gm.roughness = .init(floatLiteral: 0.05)
                gm.metallic = .init(floatLiteral: 0)
                gm.blending = .transparent(opacity: .init(floatLiteral: 0.16))
                gm.faceCulling = .none
                let glass = ModelEntity(mesh: .generateBox(width: 0.02, height: 1.4, depth: 1.2), materials: [gm])
                glass.position = SIMD3(minX, 1.55, Float(z))
                root.addChild(glass)
                let spill = SpotLight()
                spill.light.color = cityGlow
                spill.light.intensity = 15000
                spill.light.innerAngleInDegrees = 35
                spill.light.outerAngleInDegrees = 70
                spill.light.attenuationRadius = 7
                spill.position = SIMD3(minX - 0.3, 2.2, Float(z))
                spill.look(at: SIMD3(-2, 0, Float(z)), from: spill.position, relativeTo: nil)
                root.addChild(spill)
                daylight.addStreetLight(spill)
            }
        }
        for corner in [SIMD3<Float>(minX, 0, minZ), SIMD3(minX, 0, maxZ), SIMD3(maxX, 0, minZ)] {
            await place("column", at: corner)
            // a touch taller than the courses that run into it, so the two tops
            // never share a plane and fight from above
            let capH = wallH - tileH + 0.05
            let cap = WorldPrimitives.box(SIMD3(0.5, capH, 0.5), concrete, roughness: 1, corner: 0)
            cap.position = corner + SIMD3(0, tileH + capH / 2, 0)
            root.addChild(cap)
        }

        // -- the roof: the room is cut away for the camera, but a slice of it
        //    stays over the two built walls, pitched up toward the room --
        let slate = NSColor(red: 0.20, green: 0.21, blue: 0.24, alpha: 1)
        let fasciaColor = NSColor(red: 0.82, green: 0.79, blue: 0.72, alpha: 1)
        // pitched steeply, so the eave sits on the wall and the inner edge is
        // well above it: sightlines from the camera still reach the neon, the
        // clock and the top of the brick under it
        let eave: Float = 0.5, roofDepth: Float = 2.4, pitch: Float = 0.55
        let rise = roofDepth * sin(pitch), run = roofDepth * cos(pitch)
        let y0 = wallH + 0.1, y1 = y0 + rise
        // the two planes share the hip from the outer corner up to the inner
        // corner, so they meet instead of crossing
        let outerCorner = SIMD3<Float>(minX - eave, y0, minZ - eave)
        let innerCorner = SIMD3<Float>(minX - eave + run, y1, minZ - eave + run)
        let backRoof = WorldPrimitives.prism([outerCorner,
                                              SIMD3(maxX + eave, y0, minZ - eave),
                                              SIMD3(maxX + eave, y1, minZ - eave + run),
                                              innerCorner], thickness: 0.18, color: slate)
        root.addChild(backRoof)
        let leftRoof = WorldPrimitives.prism([outerCorner, innerCorner,
                                              SIMD3(minX - eave + run, y1, maxZ + eave),
                                              SIMD3(minX - eave, y0, maxZ + eave)], thickness: 0.18, color: slate)
        root.addChild(leftRoof)
        let backFascia = WorldPrimitives.box(SIMD3(floorW + eave * 2, 0.22, 0.06), fasciaColor, roughness: 0.9, corner: 0)
        backFascia.position = SIMD3(center.x, wallH - 0.02, minZ - eave)
        root.addChild(backFascia)
        let leftFascia = WorldPrimitives.box(SIMD3(0.06, 0.22, floorD + eave * 2), fasciaColor, roughness: 0.9, corner: 0)
        leftFascia.position = SIMD3(minX - eave, wallH - 0.02, center.z)
        root.addChild(leftFascia)

        // -- workstations, in clusters --
        func workstation(at p: SIMD3<Float>, yaw: Float, variant: Int) async {
            let c = cos(yaw), sn = sin(yaw)
            func local(_ lx: Float, _ ly: Float, _ lz: Float) -> SIMD3<Float> { p + SIMD3(lx * c + lz * sn, ly, -lx * sn + lz * c) }
            let desk = await place("desk", at: p, yaw: yaw, fallback: { WorldPrimitives.desk(glow: screenGreen) })
            let deskTop: Float = 0.78
            var screen = desk.findEntity(named: "screen") as? ModelEntity
            if screen == nil {
                // a real desk: give it a monitor, keyboard and mouse, and a
                // screen that glows the agent's colour
                await place("monitor", at: local(0, deskTop, -0.14), yaw: yaw)
                await place("keyboard", at: local(0, deskTop, 0.2), yaw: yaw)
                await place("mouse", at: local(0.42, deskTop, 0.2), yaw: yaw)
                let sc = WorldPrimitives.emissive(SIMD3(0.5, 0.32, 0.006), screenGreen, intensity: 1.6)
                sc.name = "screen"
                sc.position = local(0, deskTop + 0.12, -0.14 + 0.085)
                sc.orientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
                root.addChild(sc)
                screen = sc
            }
            let chairPos = local(0, 0, 0.78)
            await place("chair", at: chairPos, yaw: yaw + .pi, fallback: WorldPrimitives.chair)
            layout.seats.append(WorldSeat(kind: .desk, position: chairPos, yaw: yaw + .pi, approach: local(0, 0, 1.5), screen: screen))
            light(local(0, 1.1, 0.2), NSColor(red: 0.5, green: 0.95, blue: 0.85, alpha: 1), 320, radius: 1.7)
            // clutter, varied per desk
            switch variant % 4 {
            case 0: await place("can", at: local(0.55, deskTop, 0.05), yaw: yaw, fallback: { WorldPrimitives.can(.systemRed) })
            case 1: await place("mug", at: local(-0.55, deskTop, 0.1), yaw: yaw + 0.6)
            case 2: await place("headphones", at: local(-0.5, deskTop, -0.05), yaw: yaw - 0.4)
            default: await place("styrofoam", at: local(0.55, deskTop, -0.1), yaw: yaw + 0.3)
            }
        }
        for (i, d) in Den.desks.enumerated() {
            await workstation(at: SIMD3(d.x, 0, d.z), yaw: d.yaw, variant: i)
        }

        // -- light over the clusters: the sources only. With no ceiling the
        //    fixtures would hang in the open, so nothing is drawn --
        for (x, z) in [(Float(-3.2), Float(-1.9)), (1.8, 0.8), (5.6, -2.2), (-4.4, 2.0)] {
            daylight.addLamp(light(SIMD3(x, ceiling - 0.6, z), warm, 24000, radius: 8))
        }

        // -- lamps for the corners the pendants miss, and a soft fill from
        //    above standing in for the light they bounce off the walls --
        let shadeGlow = NSColor(red: 1.0, green: 0.8, blue: 0.55, alpha: 1)
        for l in Den.lamps {
            let p = SIMD3<Float>(l.x, 0, l.z)
            let (lamp, shade, bulbAt) = WorldPrimitives.floorLamp()
            lamp.position = p
            lamp.orientation = simd_quatf(angle: l.yaw, axis: SIMD3(0, 1, 0))
            root.addChild(lamp)
            daylight.addLamp(light(p + bulbAt, warm, 60000, radius: 7))
            daylight.addLampFace(shade, color: shadeGlow, intensity: 1.6, dayColor: NSColor(red: 0.92, green: 0.86, blue: 0.72, alpha: 1))
        }
        let fill = SpotLight()
        fill.light.color = warm
        // from high up with a narrow cone, so the inverse-square falloff is
        // nearly flat across the floor and the cone ends at the room's edge
        fill.light.intensity = 5_200_000
        // (the angles are the full cone, not the half-angle: 66 here reaches
        // the room's corners from 14 m up)
        fill.light.innerAngleInDegrees = 46
        fill.light.outerAngleInDegrees = 60
        fill.light.attenuationRadius = 40      // the window falloff is what shapes the pool; keep the floor well inside it
        fill.position = center + SIMD3(0, 14, 0)
        fill.look(at: center, from: fill.position, relativeTo: nil)
        root.addChild(fill)
        daylight.addLamp(fill)

        // -- infrastructure along the back-left --
        for (i, x) in [Float(-4.85), -4.1].enumerated() {
            let rack = WorldPrimitives.serverRack()
            rack.name = "rack\(i)"
            rack.position = SIMD3(x, 0, -4.55)
            root.addChild(rack)
        }
        await place("router", at: SIMD3(-4.1, 2.02, -4.6), scale: 0.4)
        light(SIMD3(-4.2, 1.4, -3.9), screenGreen, 500, radius: 2.5)
        // cables down the wall from the racks, and across the floor to the desks
        for (i, x) in [Float(-3.9), -0.9, 1.9, 4.9].enumerated() {
            await place("cable", at: SIMD3(x, tileH, minZ + 0.12), yaw: Float(i) * 0.7, fallback: {
                let c = WorldPrimitives.box(SIMD3(0.03, 2.4, 0.03), NSColor(white: 0.05, alpha: 1)); c.position.y = -1.2
                let h = Entity(); h.addChild(c); return h
            })
        }
        await place("pipe_detail", at: SIMD3(5.6, 0, -4.6), scale: 1.5)

        // -- walls' dressing --
        await place("whiteboard", at: SIMD3(0.6, 0, minZ + 0.07), fallback: WorldPrimitives.whiteboard)
        let sign = await place("neon", at: SIMD3(-2.4, 2.0, minZ + 0.1), fallback: { WorldPrimitives.neonSign("amux", color: neon) })
        sign.name = "neon"
        daylight.addNeon(light(SIMD3(-2.4, 2.0, minZ + 0.7), neon, 6000, radius: 4.5))
        await place("neon_sign", at: SIMD3(minX + 0.08, 1.6, 3.6), yaw: quarter)
        daylight.addNeon(light(SIMD3(minX + 0.6, 1.7, 3.6), neon, 900, radius: 3))
        await place("coat_rack", at: SIMD3(Den.coatRack.x, 0, Den.coatRack.z), scale: 2.2)
        await place("extinguisher", at: SIMD3(6.55, 0, -4.75), fallback: WorldPrimitives.extinguisher)
        // the kitchen corner: a cabinet with the coffee machine on it, next to the fridge
        await place("kitchen_cabinet", at: SIMD3(5.6, 0, -4.58), scale: 2)
        await place("coffee_machine", at: SIMD3(5.5, 0.9, -4.6), yaw: 0.1, scale: 2)
        await place("mug", at: SIMD3(5.95, 0.9, -4.45), yaw: 0.8)
        await place("mug", at: SIMD3(5.2, 0.9, -4.4), yaw: -0.5)

        // -- the wall clock, red digits on the window wall between the windows --
        let clock = WorldClock()
        clock.entity.position = SIMD3(minX + 0.08, 2.55, 0.0)
        clock.entity.orientation = simd_quatf(angle: quarter, axis: SIMD3(0, 1, 0))
        root.addChild(clock.entity)
        layout.clock = clock

        // -- the lounge in the foreground: a rug, the couch, a low table, the lamp --
        let rug = WorldPrimitives.box(SIMD3(Den.rug.w, 0.02, Den.rug.d), NSColor(red: 0.30, green: 0.22, blue: 0.24, alpha: 1), roughness: 1, corner: 0.01)
        rug.position = SIMD3(Den.rug.x, 0.01, Den.rug.z)
        root.addChild(rug)
        let rugBorder = WorldPrimitives.box(SIMD3(Den.rug.w - 0.5, 0.005, Den.rug.d - 0.5), NSColor(red: 0.36, green: 0.28, blue: 0.27, alpha: 1), roughness: 1, corner: 0)
        rugBorder.position = SIMD3(Den.rug.x, 0.023, Den.rug.z)
        root.addChild(rugBorder)
        await place("couch", at: SIMD3(Den.couch.x, 0, Den.couch.z), yaw: Den.couch.yaw, fallback: WorldPrimitives.couch)
        do {
            let c = cos(Den.couch.yaw), sn = sin(Den.couch.yaw)
            func local(_ lx: Float, _ lz: Float) -> SIMD3<Float> { SIMD3(Den.couch.x + lx * c + lz * sn, 0, Den.couch.z - lx * sn + lz * c) }
            for lx: Float in [-0.5, 0.5] {
                layout.seats.append(WorldSeat(kind: .couch, position: local(lx, 0) + SIMD3(0, 0.02, 0), yaw: Den.couch.yaw,
                                              approach: local(lx, 1.0)))
            }
        }
        let table = WorldPrimitives.box(SIMD3(1.1, 0.38, 0.55), NSColor(red: 0.30, green: 0.22, blue: 0.15, alpha: 1), roughness: 0.7, corner: 0.01)
        table.position += SIMD3(Den.table.x, 0, Den.table.z)
        table.orientation = simd_quatf(angle: Den.table.yaw, axis: SIMD3(0, 1, 0))
        root.addChild(table)
        await place("mug", at: SIMD3(Den.table.x - 0.3, 0.38, Den.table.z + 0.1), yaw: 0.4)
        for (i, p) in [SIMD3<Float>(Den.table.x + 0.25, 0.38, Den.table.z), SIMD3(Den.table.x + 0.27, 0.44, Den.table.z + 0.02)].enumerated() {
            await place("pizza_box", at: p, yaw: Float(i) * 0.3 + 0.2, fallback: WorldPrimitives.pizzaBox)
        }

        // -- the corner with the bed, the arcade and the shelf --
        let pallet = await place("pallet", at: SIMD3(Den.bed.x, 0, Den.bed.z), yaw: Den.bed.yaw, fallback: WorldPrimitives.mattress)
        if await assets.prototype("pallet") != nil {
            let m = WorldPrimitives.box(SIMD3(1.5, 0.18, 0.95), NSColor(white: 0.55, alpha: 1), roughness: 1, corner: 0.05)
            m.position = SIMD3(0, 0.19, 0)
            pallet.addChild(m)
            let blanket = WorldPrimitives.box(SIMD3(1.0, 0.06, 0.8), NSColor(red: 0.2, green: 0.24, blue: 0.3, alpha: 1), roughness: 1, corner: 0.03)
            blanket.position = SIMD3(-0.15, 0.37, 0.05)
            pallet.addChild(blanket)
            await place("pillow", at: SIMD3(0.55, 0.37, 0), yaw: 0.3, under: pallet)
        }
        await place("shelf", at: SIMD3(Den.shelf.x, 0, Den.shelf.z), yaw: Den.shelf.yaw)
        await place("boxes", at: SIMD3(-5.4, 0, 0.5), yaw: 0.4)
        await place("arcade", at: SIMD3(Den.arcade.x, 0, Den.arcade.z), yaw: Den.arcade.yaw, fallback: WorldPrimitives.arcadeCabinet)
        light(SIMD3(Den.arcade.x + 0.7, 1.3, Den.arcade.z), NSColor(red: 1.0, green: 0.4, blue: 0.75, alpha: 1), 2500, radius: 3)
        await place("fridge", at: SIMD3(Den.fridge.x, 0, Den.fridge.z), yaw: Den.fridge.yaw)
        let crate = await place("crate", at: SIMD3(Den.crate.x, 0, Den.crate.z), yaw: Den.crate.yaw, fallback: { WorldPrimitives.cardboardBox(0.6) })
        await place("crt", at: SIMD3(0, 0.65, 0), yaw: -0.6, under: crate, fallback: WorldPrimitives.crt)

        // -- the mess --
        await place("can_crushed", at: SIMD3(2.4, 0, 3.0), yaw: 1.1)
        await place("can_crushed", at: SIMD3(5.6, 0, 2.9), yaw: 0.3)
        await place("papers", at: SIMD3(1.2, 0.005, 4.6), yaw: 0.5)
        await place("papers", at: SIMD3(-2.4, 0.005, 3.2), yaw: -1.2)
        await place("papers", at: SIMD3(-1.0, 0.005, -0.4), yaw: 0.9)
        await place("skateboard", at: SIMD3(-1.3, 0, 5.9), yaw: 0.5)
        await place("trash_bags", at: SIMD3(7.3, 0, 0.6), yaw: 0.8)
        await place("cup", at: SIMD3(3.4, 0.02, 2.6), yaw: 0.2)

        // -- outside: the room is on the ground in a warehouse yard; see WorldYard --
        let ground = WorldPrimitives.plane(160, 160, NSColor(red: 0.36, green: 0.36, blue: 0.37, alpha: 1), roughness: 1)
        ground.position.y = -0.14
        root.addChild(ground)
        await WorldYard.build(under: root, daylight: daylight, layout: &layout) { name, p, yaw, scale, parent, fallback in
            await place(name, at: p, yaw: yaw, scale: scale, under: parent, fallback: fallback)
        }

        // -- the sky: the renderer has no skybox, so it is a dome around everything --
        if let sky = await skyDome() {
            root.addChild(sky)
            daylight.sky = sky
        }

        layout.focus = SIMD3(center.x, 0.6, center.z - 0.6)
        return layout
    }

    /// The gradient as a textured sphere seen from inside, at a distance the
    /// camera never reaches. WorldDaylight repaints it as the hour changes.
    static func skyDome() async -> ModelEntity? {
        guard let img = skyImage(zenith: [0.06, 0.08, 0.16], horizon: [0.04, 0.05, 0.09], ground: [0.03, 0.03, 0.04]),
              let tex = try? await TextureResource(image: img, options: .init(semantic: .color)) else { return nil }
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(tex))
        m.faceCulling = .front
        let dome = ModelEntity(mesh: .generateSphere(radius: 160), materials: [m])
        dome.name = "sky"
        dome.orientation = simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0))
        return dome
    }

    /// An equirectangular gradient: zenith at the top, horizon across the
    /// middle, ground below. Used for both the dome and the image-based light.
    static func skyImage(zenith: SIMD3<Float>, horizon: SIMD3<Float>, ground: SIMD3<Float>) -> CGImage? {
        let w = 512, h = 256
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func cg(_ v: SIMD3<Float>) -> CGColor { CGColor(red: CGFloat(v.x), green: CGFloat(v.y), blue: CGFloat(v.z), alpha: 1) }
        let colors = [cg(zenith), cg(horizon), cg(ground)] as CFArray
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) else { return nil }
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: 0, y: 0), options: [])
        return ctx.makeImage()
    }
}
