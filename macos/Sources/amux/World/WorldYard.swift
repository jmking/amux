import RealityKit
import AppKit
import simd

// MARK: - The yard
//
// The room is on the ground in a warehouse estate. Beyond the back wall, a
// long brick-and-metal facade with a roller door, a parked lorry and a lit
// loading bay; beyond the window wall, a corrugated wing behind a run of
// chain-link with containers, a skip and drums against it; sodium lamp posts
// and floodlights that come on at dusk; pallets, tyres, cones, bags, puddles
// and cracked asphalt where the concrete has given up. Nothing intrudes on the
// path from the spawn point through the door.
//
// Layout follows Assets/work/yard-design.json, which was worked out against
// the camera's sightlines: what shows above the 2.4 m walls, through the door
// and through each window.

@MainActor
enum WorldYard {
    typealias Place = (String, SIMD3<Float>, Float, Float, Entity?, (() -> Entity)?) async -> Entity

    static let y: Float = -0.13                     // everything outdoors stands here
    static let sodium = NSColor(red: 1.0, green: 0.72, blue: 0.42, alpha: 1)
    static let flood = NSColor(red: 0.85, green: 0.90, blue: 1.0, alpha: 1)
    static let bayWarm = NSColor(red: 1.0, green: 0.82, blue: 0.6, alpha: 1)
    static let officeWarm = NSColor(red: 1.0, green: 0.90, blue: 0.72, alpha: 1)

    static func build(under root: Entity, daylight: WorldDaylight, layout: inout WorldLayout, place placeRaw: @escaping Place) async {
        // the yard is a backdrop: every kit piece goes a light grey, so by day
        // it reads as a pale wash behind the room and by night the street
        // lights are the only colour in it
        let place: Place = { name, p, yaw, scale, parent, fallback in
            let e = await placeRaw(name, p, yaw, scale, parent, fallback)
            switch name {
            case "cone": break                                   // one accent of colour
            case "yard_asphalt": greyOut(e, fixed: 0.30)          // a step darker than the slab
            default: greyOut(e)
            }
            return e
        }
        func deg(_ d: Float) -> Float { d * .pi / 180 }
        func box(_ size: SIMD3<Float>, _ color: NSColor, at p: SIMD3<Float>, yaw: Float = 0, roughness: Float = 1) {
            let b = WorldPrimitives.box(size, color, roughness: roughness, corner: 0)
            b.position += p
            b.orientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
            root.addChild(b)
        }

        // -- ground: a yard slab a step below the plinth, a stoop at the door,
        //    lane paint, cracked asphalt, puddles --
        let slab = WorldPrimitives.plane(44, 34, NSColor(red: 0.37, green: 0.37, blue: 0.38, alpha: 1))
        slab.position = SIMD3(-2, -0.135, -1.5)
        root.addChild(slab)
        box(SIMD3(2.4, 0.12, 1.7), NSColor(white: 0.46, alpha: 1), at: SIMD3(3, -0.12, -6.05))
        let paint = NSColor(red: 0.62, green: 0.58, blue: 0.42, alpha: 1)
        for x: Float in [0.4, 5.6] { box(SIMD3(0.12, 0.004, 8), paint, at: SIMD3(x, -0.128, -13)) }
        let white = NSColor(red: 0.6, green: 0.6, blue: 0.58, alpha: 1)
        for x: Float in [7.5, 10.5, 13.5] { box(SIMD3(0.12, 0.004, 4), white, at: SIMD3(x, -0.128, -14.8)) }
        for (p, yaw) in [(SIMD3<Float>(-7.6, y, -6.2), Float(25)), (SIMD3(-3, y, -9.5), 110), (SIMD3(-13.5, y, 3.5), -40),
                         (SIMD3(8.5, y, -9), 150), (SIMD3(-9, y, 7.5), 65), (SIMD3(8.5, y, 5.5), 50)] {
            _ = await place("yard_asphalt", p, deg(yaw), 1, nil, nil)
        }
        for (x, z, w, d, yaw) in [(Float(-8.2), Float(0.2), Float(2.4), Float(1.6), Float(30)), (-8.6, -5.2, 1.8, 1.2, -20),
                                  (0.6, -7.8, 2.0, 1.3, 60), (-6.2, -14.0, 3.0, 1.8, 10), (7.5, 2.0, 2.0, 1.2, 45), (-11.5, 5.5, 2.6, 1.5, -35)] {
            root.addChild(puddle(w, d, at: SIMD3(x, -0.129, z), yaw: deg(yaw)))
        }

        // -- the warehouse: two rows of facade tiles 12 m behind the back wall,
        //    a parapet, a roof, a canopy over the working bay, roof plant --
        let facadeZ: Float = -17
        for x in stride(from: -18, through: 15, by: 3) {
            let ground: String
            switch x {
            case -9: ground = "facade_garage"          // the closed second bay
            case 3: ground = "facade_garage"           // the working bay, in line with the door
            case 9: ground = "facade_window"
            case -15, -3, 6, 12: ground = "facade_painted"
            default: ground = "facade_wall"
            }
            _ = await place(ground, SIMD3(Float(x), y, facadeZ), .pi, 1, nil, nil)
            let upper: String
            switch x {
            case -6, 3, 9: upper = "facade_window"
            case -12, 0, 15: upper = "facade_wall"
            default: upper = "facade_painted"
            }
            _ = await place(upper, SIMD3(Float(x), 2.87, facadeZ), .pi, 1, nil, nil)
        }
        box(SIMD3(36.3, 0.35, 0.4), NSColor(white: 0.44, alpha: 1), at: SIMD3(-1.5, 5.7, -17.1))
        box(SIMD3(36, 0.3, 12), NSColor(white: 0.34, alpha: 1), at: SIMD3(-1.5, 5.45, -23.1))
        _ = await place("roof_metal", SIMD3(3, 2.87, -15.5), .pi / 2, 1, nil, nil)
        _ = await place("ac_stacked", SIMD3(0.5, 5.9, -20.5), deg(20), 1, nil, nil)
        _ = await place("ac_unit", SIMD3(-9.5, 5.9, -19.5), 0, 1, nil, nil)
        _ = await place("antenna", SIMD3(12.5, 5.9, -19.0), 0, 1, nil, nil)
        _ = await place("tv_tower", SIMD3(-22, 5.9, -22), 0, 1, nil, nil)
        // the bay glows warm after dusk; office windows and the sign with the lamps
        let bay = WorldPrimitives.emissive(SIMD3(2.4, 2.2, 0.02), bayWarm, intensity: 1.1)
        bay.position = SIMD3(3, 0, -16.83)
        root.addChild(bay)
        let bayLight = PointLight()
        bayLight.light.color = bayWarm; bayLight.light.intensity = 25000; bayLight.light.attenuationRadius = 10
        bayLight.position = SIMD3(3, 1.6, -16.0)
        root.addChild(bayLight)
        daylight.addLamp(bayLight, face: bay, faceColor: bayWarm, faceIntensity: 1.1)
        for p in [SIMD3<Float>(-6, 3.9, -16.9), SIMD3(3, 3.9, -16.9), SIMD3(9, 3.9, -16.9), SIMD3(9, 0.9, -16.9)] {
            let w = WorldPrimitives.emissive(SIMD3(1.3, 1.3, 0.02), officeWarm, intensity: 0.9)
            w.position = p
            root.addChild(w)
            daylight.addLampFace(w, color: officeWarm, intensity: 0.9)
        }
        box(SIMD3(3.2, 0.7, 0.15), NSColor(white: 0.36, alpha: 1), at: SIMD3(3, 5.9, -17.0))
        let sign = WorldPrimitives.emissive(SIMD3(2.9, 0.45, 0.02), NSColor(red: 0.9, green: 0.9, blue: 0.85, alpha: 1), intensity: 0.7)
        sign.position = SIMD3(3, 6.02, -16.92)
        root.addChild(sign)
        daylight.addLampFace(sign, color: NSColor(red: 0.9, green: 0.9, blue: 0.85, alpha: 1), intensity: 0.7)
        if let tag = await WorldLabel.make(.init(text: "UNIT 7", textColor: NSColor(white: 0.1, alpha: 1), background: nil, fontSize: 30, weight: .black)) {
            tag.position = SIMD3(3, 6.05, -16.9); tag.scale = SIMD3(repeating: 1.1)
            root.addChild(tag)
        }
        // floodlight over the bay, aimed down the lane
        addFlood(root, daylight, at: SIMD3(3, 5.3, -16.7), aim: SIMD3(3, y, -11.5), lumens: 80000, inner: 25, outer: 60, radius: 26)

        // -- the wing: a corrugated shed beyond the window wall, its own bay,
        //    parapet and roof, a floodlight on the eave, the yard's tag --
        let wingX: Float = -17
        for z in stride(from: -15, through: 6, by: 3) {
            let name = z == -6 ? "facade_garage_metal" : "facade_metal"
            _ = await place(name, SIMD3(wingX, y, Float(z) - 0.5), -.pi / 2, 1, nil, nil)
        }
        box(SIMD3(0.4, 0.35, 24.2), NSColor(white: 0.44, alpha: 1), at: SIMD3(-17.1, 2.7, -5))
        box(SIMD3(12, 0.3, 24), NSColor(white: 0.34, alpha: 1), at: SIMD3(-23.1, 2.45, -5))
        _ = await place("ac_unit", SIMD3(-20, 2.9, -1.0), .pi / 2, 1, nil, nil)
        addFlood(root, daylight, at: SIMD3(-16.7, 2.75, -8), aim: SIMD3(-10.5, y, -9), lumens: 50000, inner: 30, outer: 65, radius: 20)
        if let tag = await WorldGraffiti.make("HELLO FRIEND", color: NSColor(red: 1.0, green: 0.25, blue: 0.55, alpha: 1), height: 2.4, seed: 7) {
            tag.position = SIMD3(-16.9, 0.15 + tag.position.y, -1.2)   // make() anchors the quad's bottom at the origin
            tag.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))
            root.addChild(tag)
        }
        if let tag = await WorldGraffiti.make("404", color: NSColor(red: 0.3, green: 0.9, blue: 0.95, alpha: 1), height: 2.2, seed: 3) {
            tag.position = SIMD3(-1.6, 1.0 + tag.position.y, -16.9)
            root.addChild(tag)
        }

        // -- chain-link: along x behind the back wall, along z beyond the
        //    windows, and the gate swung open into the yard --
        let mesh = await fenceMaterial()
        for x in stride(from: -11, through: -2, by: 3) {
            root.addChild(fencePanel(3, mesh, at: SIMD3(Float(x), y, -13), yaw: 0))
        }
        for z in stride(from: -11.5, through: 9.5, by: 3) {
            root.addChild(fencePanel(3, mesh, at: SIMD3(-12.5, y, Float(z)), yaw: .pi / 2))
        }
        root.addChild(fencePanel(3.5, mesh, at: SIMD3(-0.5, y, -11.25), yaw: .pi / 2, gate: true))

        // -- containers, skip, drums and the scrap along the fence --
        let tagged = await place("container_tagged", SIMD3(-8.5, y, -11.5), .pi / 2, 1, nil, nil)
        tagged.scale = SIMD3(0.85, 1, 1.5)
        let plain = await place("container", SIMD3(-11.0, y, -7.0), 0, 1, nil, nil)
        plain.scale = SIMD3(0.85, 1, 1.5)
        // doors on the end seen through the window
        box(SIMD3(1.15, 2.5, 0.04), NSColor(white: 0.5, alpha: 1), at: SIMD3(-11.6, y, -3.92))
        box(SIMD3(1.15, 2.5, 0.04), NSColor(white: 0.5, alpha: 1), at: SIMD3(-10.4, y, -3.92))
        for x: Float in [-11.9, -11.3, -10.7, -10.1] { box(SIMD3(0.04, 2.3, 0.04), NSColor(white: 0.56, alpha: 1), at: SIMD3(x, y + 0.1, -3.88)) }
        let ladder = await place("ladder", SIMD3(-6.5, y, -9.4), .pi / 2, 1, nil, nil)
        ladder.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: deg(-20), axis: SIMD3(1, 0, 0))
        _ = await place("skip_open", SIMD3(-8.6, y, -8.6), .pi, 1, nil, nil)
        for (p, yaw) in [(SIMD3<Float>(-10.9, y, -3.2), Float(0)), (SIMD3(-10.3, y, -2.8), 40), (SIMD3(-10.6, y, -2.25), 110)] {
            _ = await place("drum", p, deg(yaw), 1, nil, nil)
        }
        _ = await place("dumpster_open", SIMD3(-15.9, y, -10.8), -.pi / 2, 1, nil, nil)
        _ = await place("pallet_broken", SIMD3(-14.2, y, -12.2), deg(15), 1, nil, nil)
        _ = await place("pallet_broken", SIMD3(-14.5, 0.05, -12.0), deg(-30), 1, nil, nil)
        _ = await place("pallet_yard", SIMD3(-13.9, y, -14.9), deg(50), 1, nil, nil)

        // -- outside the front window: pallets, tyres, bags --
        for (i, yaw) in [Float(0), 4, -3].enumerated() {
            _ = await place("pallet_yard", SIMD3(-8.2, y + Float(i) * 0.18, 1.0), deg(yaw), 1, nil, nil)
        }
        _ = await place("pallet_broken", SIMD3(-9.7, y, 3.2), deg(25), 1, nil, nil)
        for i in 0..<3 { root.addChild(tyre(at: SIMD3(-10.3, y + Float(i) * 0.22, 1.7))) }
        root.addChild(tyre(at: SIMD3(-13.8, y, -2.6)))
        root.addChild(tyre(at: SIMD3(-14.3, y, -2.1)))
        _ = await place("trash_bags", SIMD3(-7.3, y, 3.9), deg(40), 1, nil, nil)
        _ = await place("pallet_yard", SIMD3(-8.4, y, 6.3), deg(15), 1, nil, nil)
        _ = await place("scaffold", SIMD3(-15.85, y, 4.5), 0, 1, nil, nil)
        _ = await place("scaffold", SIMD3(-15.85, 1.87, 4.5), 0, 1, nil, nil)
        _ = await place("barrier_striped", SIMD3(-13.4, y, 6.8), deg(80), 1, nil, nil)

        // -- poles and wires in the strip --
        _ = await place("elec_pole", SIMD3(-14.8, y, -7.5), .pi / 2, 1, nil, nil)
        _ = await place("elec_wires", SIMD3(-14.8, 4.55, -9.5), .pi / 2, 1, nil, nil)
        _ = await place("elec_wires", SIMD3(-14.8, 4.55, -14.5), .pi / 2, 1, nil, nil)
        box(SIMD3(0.3, 0.4, 0.15), NSColor(white: 0.4, alpha: 1), at: SIMD3(-15, 5.0, -16.9))

        // -- the lane: lorry, pallets, the gas tank, barriers, the blinking bollard --
        _ = await place("truck_box", SIMD3(-7.0, y, -15.2), .pi / 2, 1, nil, nil)   // parked at the closed bay
        for (i, yaw) in [Float(0), 5, -4, 8].enumerated() {
            _ = await place("pallet_yard", SIMD3(0.6, y + Float(i) * 0.18, -15.4), deg(yaw), 1, nil, nil)
        }
        _ = await place("crate", SIMD3(0.55, 0.59, -15.4), deg(20), 1, nil, nil)
        _ = await place("boxes", SIMD3(1.6, y, -14.0), deg(40), 1, nil, nil)
        _ = await place("propane_tank", SIMD3(7.0, y, -16.2), deg(200), 1, nil, nil)
        for (p, yaw) in [(SIMD3<Float>(5.6, y, -16.1), Float(0)), (SIMD3(6.15, y, -16.45), 70), (SIMD3(5.85, y, -15.5), 150)] {
            _ = await place("drum", p, deg(yaw), 1, nil, nil)
        }
        _ = await place("scaffold", SIMD3(12, y, -15.85), 0, 1, nil, nil)
        _ = await place("scaffold", SIMD3(12, 1.87, -15.85), 0, 1, nil, nil)
        _ = await place("barrier_striped", SIMD3(6.8, y, -12.4), deg(10), 1, nil, nil)
        _ = await place("barrier_concrete", SIMD3(10, y, -12.8), 0, 1, nil, nil)
        _ = await place("barrier_concrete", SIMD3(12, y, -12.8), 0, 1, nil, nil)
        _ = await place("warning_light", SIMD3(0.6, y, -12.6), 0, 1, nil, nil)
        let amber = NSColor(red: 1.0, green: 0.6, blue: 0.12, alpha: 1)
        let blinkFace = WorldPrimitives.emissive(SIMD3(0.16, 0.12, 0.16), amber, intensity: 4)
        blinkFace.position = SIMD3(0.6, 0.95, -12.6)
        root.addChild(blinkFace)
        let blink = PointLight()
        blink.light.color = amber; blink.light.intensity = 1500; blink.light.attenuationRadius = 4
        blink.position = SIMD3(0.6, 1.05, -12.6)
        root.addChild(blink)
        layout.blinker = (blink, blinkFace)
        _ = await place("cone", SIMD3(-2.6, y, -12.2), 0, 1, nil, nil)
        _ = await place("cone", SIMD3(1.4, y, -7.2), 0, 1, nil, nil)

        // -- by the door: the bin, bags, a crate, cardboard --
        _ = await place("dumpster", SIMD3(5.4, y, -6.9), 0, 1, nil, nil)
        _ = await place("trash_bags", SIMD3(6.7, y, -6.5), deg(30), 1, nil, nil)
        _ = await place("trash_bags", SIMD3(4.7, y, -7.9), deg(100), 1, nil, nil)
        _ = await place("crate", SIMD3(6.9, y, -8.4), deg(20), 1, nil, nil)
        _ = await place("boxes", SIMD3(6.3, y, -9.3), deg(60), 1, nil, nil)

        // -- in front of the room, kept low so it never crosses the floor on screen --
        _ = await place("drum", SIMD3(7.6, y, 2.4), 0, 1, nil, nil)
        _ = await place("drum", SIMD3(8.1, y, 2.9), deg(60), 1, nil, nil)
        _ = await place("cone", SIMD3(2.5, y, 7.0), 0, 1, nil, nil)
        _ = await place("trash_bags", SIMD3(8.4, y, -1.5), deg(80), 1, nil, nil)

        // -- lights outside: the LED lights at the windows and door, sodium posts --
        let lampCold = NSColor(red: 0.75, green: 0.85, blue: 1.0, alpha: 1)
        let lampWarm = NSColor(red: 1.0, green: 0.86, blue: 0.62, alpha: 1)
        for (p, yaw, color) in [(SIMD3<Float>(-8.4, y, -2.2), Float.pi / 2, lampCold),
                                (SIMD3(-8.4, y, 2.2), Float.pi / 2, lampCold),
                                (SIMD3(5.2, y, -8.2), Float(0), lampWarm)] {
            _ = await place("streetlight", p, yaw, 1, nil, nil)
            let head = WorldPrimitives.emissive(SIMD3(0.36, 0.12, 0.36), color, intensity: 5)
            head.position = p + SIMD3(0, 2.75, 0)
            root.addChild(head)
            let l = PointLight()
            l.light.color = color; l.light.intensity = 80000; l.light.attenuationRadius = 15
            l.position = p + SIMD3(0, 2.6, 0)
            root.addChild(l)
            daylight.addStreetLight(l, face: head, faceColor: color, faceIntensity: 5)
        }
        for (p, yaw, head) in [(SIMD3<Float>(-13.4, y, -13.6), Float(-135), SIMD3<Float>(-12.7, 4.55, -12.9)),
                               (SIMD3(-11.8, y, 9.4), -45, SIMD3(-11.1, 4.55, 8.7)),
                               (SIMD3(11.5, y, -10.8), 90, SIMD3(10.55, 4.55, -10.8))] {
            _ = await place("lamp_post", p, deg(yaw), 1, nil, nil)
            let face = WorldPrimitives.emissive(SIMD3(0.5, 0.15, 0.3), sodium, intensity: 5)
            face.position = head
            root.addChild(face)
            let l = PointLight()
            l.light.color = sodium; l.light.intensity = 120000; l.light.attenuationRadius = 20
            l.position = head
            root.addChild(l)
            daylight.addStreetLight(l, face: face, faceColor: sodium, faceIntensity: 5)
        }

        // -- the estate beyond --
        _ = await place("building_wide", SIMD3(-6, y, -42), 0, 1, nil, nil)
        _ = await place("building_low", SIMD3(-40, y, -12), .pi / 2, 1, nil, nil)
        _ = await place("building_low", SIMD3(24, y, -32), 0, 1, nil, nil)
    }

    // MARK: the grey wash

    /// Replaces every lit material under `e` with a matte grey of roughly the
    /// original's brightness; emissive parts (lamp heads) are left alone.
    private static func greyOut(_ e: Entity, fixed: Float? = nil) {
        if let me = e as? ModelEntity, var model = me.model {
            model.materials = model.materials.map { m in
                var g: Float = fixed ?? 0.48
                if let pbr = m as? PhysicallyBasedMaterial {
                    // a lit part: emissive colour with some brightness (the
                    // intensity alone is 1 on every loaded material)
                    if let ec = pbr.emissiveColor.color.usingColorSpace(.sRGB),
                       Float(0.2126 * ec.redComponent + 0.7152 * ec.greenComponent + 0.0722 * ec.blueComponent) * pbr.emissiveIntensity > 0.05 {
                        return m
                    }
                    if fixed == nil, pbr.baseColor.texture == nil, let c = pbr.baseColor.tint.usingColorSpace(.sRGB) {
                        let lum = Float(0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
                        g = 0.34 + 0.26 * pow(max(0, lum), 0.6)
                    }
                }
                var out = PhysicallyBasedMaterial()
                out.baseColor = .init(tint: NSColor(white: CGFloat(g), alpha: 1))
                out.roughness = .init(floatLiteral: 0.9)
                out.metallic = .init(floatLiteral: 0)
                return out
            }
            me.model = model
        }
        for c in e.children { greyOut(c, fixed: fixed) }
    }

    // MARK: pieces the packs do not have

    private static func addFlood(_ root: Entity, _ daylight: WorldDaylight, at p: SIMD3<Float>, aim: SIMD3<Float>,
                                 lumens: Float, inner: Float, outer: Float, radius: Float) {
        let housing = WorldPrimitives.box(SIMD3(0.3, 0.2, 0.25), NSColor(white: 0.42, alpha: 1), roughness: 0.8, corner: 0)
        housing.position = p - SIMD3(0, 0.1, 0)
        root.addChild(housing)
        let face = WorldPrimitives.emissive(SIMD3(0.26, 0.16, 0.02), flood, intensity: 6)
        let toward = simd_normalize(aim - p)
        face.position = p + toward * 0.14 - SIMD3(0, 0.08, 0)
        face.look(at: aim, from: face.position, relativeTo: nil)
        root.addChild(face)
        let spot = SpotLight()
        spot.light.color = flood
        spot.light.intensity = lumens
        spot.light.innerAngleInDegrees = inner
        spot.light.outerAngleInDegrees = outer
        spot.light.attenuationRadius = radius
        spot.position = p
        spot.look(at: aim, from: p, relativeTo: nil)
        root.addChild(spot)
        daylight.addStreetLight(spot)
        daylight.addStreetFace(face, color: flood, intensity: 6)
    }

    /// Wet concrete: dark, nearly a mirror, so it takes the sky by day and the
    /// lamps by night.
    private static func puddle(_ w: Float, _ d: Float, at p: SIMD3<Float>, yaw: Float) -> Entity {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: NSColor(red: 0.24, green: 0.25, blue: 0.28, alpha: 1))
        m.roughness = .init(floatLiteral: 0.12)
        m.metallic = .init(floatLiteral: 0)
        let e = ModelEntity(mesh: .generatePlane(width: w, depth: d, cornerRadius: min(w, d) * 0.45), materials: [m])
        e.position = p
        e.orientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        return e
    }

    private static func tyre(at p: SIMD3<Float>) -> Entity {
        let root = Entity()
        var black = PhysicallyBasedMaterial()
        black.baseColor = .init(tint: NSColor(white: 0.3, alpha: 1)); black.roughness = .init(floatLiteral: 0.9)
        let t = ModelEntity(mesh: .generateCylinder(height: 0.22, radius: 0.35), materials: [black])
        t.position.y = 0.11
        var grey = PhysicallyBasedMaterial()
        grey.baseColor = .init(tint: NSColor(white: 0.52, alpha: 1)); grey.roughness = .init(floatLiteral: 0.7); grey.metallic = .init(floatLiteral: 0)
        let rim = ModelEntity(mesh: .generateCylinder(height: 0.24, radius: 0.2), materials: [grey])
        rim.position.y = 0.11
        root.addChild(t); root.addChild(rim)
        root.position = p
        return root
    }

    /// A diamond mesh drawn once and tiled across every panel.
    private static func fenceMaterial() async -> UnlitMaterial {
        var m = UnlitMaterial(color: NSColor(white: 0.6, alpha: 0.5))
        m.blending = .transparent(opacity: 0.55)
        let n = 64
        if let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.clear(CGRect(x: 0, y: 0, width: n, height: n))
            ctx.setStrokeColor(CGColor(red: 0.66, green: 0.67, blue: 0.69, alpha: 1))
            ctx.setLineWidth(3)
            let s = CGFloat(n)
            for k in [-1, 0, 1] {
                let o = CGFloat(k) * s
                ctx.move(to: CGPoint(x: o, y: 0)); ctx.addLine(to: CGPoint(x: o + s, y: s))
                ctx.move(to: CGPoint(x: o + s, y: 0)); ctx.addLine(to: CGPoint(x: o, y: s))
            }
            ctx.strokePath()
            if let img = ctx.makeImage(), let tex = try? await TextureResource(image: img, options: .init(semantic: .color)) {
                m.color = .init(tint: .white, texture: .init(tex))
                m.opacityThreshold = 0.2
            }
        }
        return m
    }

    /// One panel of chain-link: two posts, a top rail, the mesh, a barbed line.
    private static func fencePanel(_ width: Float, _ mesh: UnlitMaterial, at p: SIMD3<Float>, yaw: Float, gate: Bool = false) -> Entity {
        let root = Entity()
        let steel = NSColor(white: 0.5, alpha: 1)
        let h: Float = 2.4
        for x in [-width / 2, width / 2] {
            let post = WorldPrimitives.box(SIMD3(0.06, h, 0.06), steel, roughness: 0.8, corner: 0)
            post.position += SIMD3(x, 0, 0)
            root.addChild(post)
        }
        let rail = WorldPrimitives.box(SIMD3(width, 0.05, 0.05), steel, roughness: 0.8, corner: 0)
        rail.position += SIMD3(0, h - 0.05, 0)
        root.addChild(rail)
        let panel = ModelEntity(mesh: .generatePlane(width: width, height: h - 0.1), materials: [mesh])
        var pm = mesh
        pm.textureCoordinateTransform = .init(scale: SIMD2(width / 0.12, (h - 0.1) / 0.12))
        panel.model?.materials = [pm]
        panel.position = SIMD3(0, (h - 0.1) / 2 + 0.05, 0)
        root.addChild(panel)
        let barb = WorldPrimitives.box(SIMD3(width, 0.02, 0.02), NSColor(white: 0.55, alpha: 1), roughness: 0.6, corner: 0)
        barb.position += SIMD3(0, h + 0.12, 0)
        root.addChild(barb)
        if gate {
            let brace = WorldPrimitives.box(SIMD3(width * 1.1, 0.04, 0.04), steel, roughness: 0.8, corner: 0)
            brace.position += SIMD3(0, h / 2, 0)
            brace.orientation = simd_quatf(angle: atan2(h, width), axis: SIMD3(0, 0, 1))
            root.addChild(brace)
        }
        root.position = p
        root.orientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        return root
    }
}
