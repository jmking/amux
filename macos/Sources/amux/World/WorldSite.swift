import RealityKit
import AppKit
import simd

// MARK: - The site
//
// The street and the block around the den, laid from the tables in
// WorldSiteData (generated from the site plan): road tiles on a grid, ground
// areas, the neighbouring buildings, the compound fence, props, the light
// sources, and a few silhouettes further out. Everything placed goes through
// the yard's grey wash except the road tiles, whose kit colours are already
// greys with white and yellow lines.

@MainActor
enum WorldSite {
    struct Piece {
        let name: String
        let x: Float, z: Float
        let yaw: Float       // degrees; 0 = model faces -z, 90 faces -x, 180 faces +z
        let scale: Float
        init(_ name: String, _ x: Float, _ z: Float, yaw: Float = 0, scale: Float = 1) {
            self.name = name; self.x = x; self.z = z; self.yaw = yaw; self.scale = scale
        }
    }
    struct Area {
        let kind: String
        let x: Float, z: Float, w: Float, d: Float
        init(_ kind: String, _ x: Float, _ z: Float, _ w: Float, _ d: Float) {
            self.kind = kind; self.x = x; self.z = z; self.w = w; self.d = d
        }
    }
    struct Fence {
        let kind: String
        let x: Float, z: Float, yaw: Float, length: Float
        init(_ kind: String, _ x: Float, _ z: Float, yaw: Float, length: Float) {
            self.kind = kind; self.x = x; self.z = z; self.yaw = yaw; self.length = length
        }
    }
    struct Light {
        let kind: String
        let x: Float, y: Float, z: Float
        let color: String
        let lumens: Float
        init(_ kind: String, _ x: Float, _ y: Float, _ z: Float, color: String, lumens: Float) {
            self.kind = kind; self.x = x; self.y = y; self.z = z; self.color = color; self.lumens = lumens
        }
    }

    static let y = WorldYard.y

    static func build(under root: Entity, daylight: WorldDaylight, layout: inout WorldLayout, place: WorldYard.Place) async {
        func rad(_ d: Float) -> Float { d * .pi / 180 }

        // -- ground areas: thin slabs a hair above the yard slab, in greys by kind --
        for a in WorldSiteData.areas {
            let k = a.kind.lowercased()
            let (shade, lift): (Float, Float) = {
                if k.contains("paint") || k.contains("line") { return (0.50, 0.008) }
                if k.contains("grass") || k.contains("weed") || k.contains("verge") { return (0.33, 0.003) }
                if k.contains("gravel") || k.contains("dirt") || k.contains("vacant") { return (0.36, 0.003) }
                if k.contains("footpath") || k.contains("pavement") || k.contains("sidewalk") || k.contains("kerb") || k.contains("apron") || k.contains("stoop") { return (0.42, 0.006) }
                if k.contains("asphalt") || k.contains("road") || k.contains("lot") || k.contains("car") || k.contains("bay") { return (0.27, 0.002) }
                return (0.36, 0.002)
            }()
            let tint: NSColor = k.contains("paint") ? NSColor(red: 0.56, green: 0.52, blue: 0.38, alpha: 1)
                : (k.contains("grass") || k.contains("weed") || k.contains("verge")) ? NSColor(red: 0.30, green: 0.34, blue: 0.28, alpha: 1)
                : NSColor(white: CGFloat(shade), alpha: 1)
            let slab = WorldPrimitives.box(SIMD3(a.w, 0.02, a.d), tint, roughness: 1, corner: 0)
            slab.position = SIMD3(a.x, y + lift, a.z)
            root.addChild(slab)
        }

        // -- roads: kit tiles keep their own colours --
        for r in WorldSiteData.roads {
            let e = await place(r.name, SIMD3(r.x, y + 0.01, r.z), rad(r.yaw), r.scale, nil, nil)
            e.name = "road:" + r.name
        }

        // -- buildings and the distant silhouettes --
        for b in WorldSiteData.buildings + WorldSiteData.distant {
            _ = await place(b.name, SIMD3(b.x, y, b.z), rad(b.yaw), b.scale, nil, nil)
        }

        // -- the compound fence, in 3 m chain-link panels along each segment --
        let mesh = await WorldYard.fenceMaterial()
        for s in WorldSiteData.fence {
            let yaw = rad(s.yaw)
            let dir = SIMD3<Float>(sin(yaw), 0, cos(yaw))       // a panel at yaw 0 runs along x; the plan gives the run's heading
            let along = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
            _ = dir
            let panels = max(1, Int((s.length / 3).rounded()))
            let panelLen = s.length / Float(panels)
            let start = SIMD3<Float>(s.x, y, s.z) - along * (s.length / 2 - panelLen / 2)
            for i in 0..<panels {
                let p = start + along * (Float(i) * panelLen)
                let gate = s.kind.lowercased().contains("gate")
                root.addChild(WorldYard.fencePanel(panelLen, mesh, at: p, yaw: yaw, gate: gate))
            }
        }

        // -- props: kit pieces, or the few small things drawn here --
        for p in WorldSiteData.props {
            if p.name.hasPrefix("primitive:") {
                if let e = primitive(String(p.name.dropFirst("primitive:".count)), scale: p.scale) {
                    e.position += SIMD3(p.x, y, p.z)
                    e.orientation = simd_quatf(angle: rad(p.yaw), axis: SIMD3(0, 1, 0))
                    root.addChild(e)
                }
                continue
            }
            _ = await place(p.name, SIMD3(p.x, y, p.z), rad(p.yaw), p.scale, nil, nil)
        }

        // -- lights: the sources the plan asks for, with a small glowing head --
        for l in WorldSiteData.lights {
            let color = color(for: l.color, kind: l.kind)
            let kind = l.kind.lowercased()
            if kind.contains("flood") || kind.contains("spot") {
                let spot = SpotLight()
                spot.light.color = color
                spot.light.intensity = l.lumens
                spot.light.innerAngleInDegrees = 30
                spot.light.outerAngleInDegrees = 70
                spot.light.attenuationRadius = max(12, l.y * 5)
                spot.position = SIMD3(l.x, l.y, l.z)
                spot.look(at: SIMD3(l.x + 0.01, y, l.z + 3), from: spot.position, relativeTo: nil)
                root.addChild(spot)
                daylight.addStreetLight(spot)
                let face = WorldPrimitives.emissive(SIMD3(0.3, 0.16, 0.16), color, intensity: 5)
                face.position = SIMD3(l.x, l.y - 0.1, l.z)
                root.addChild(face)
                daylight.addStreetFace(face, color: color, intensity: 5)
            } else {
                let pl = PointLight()
                pl.light.color = color
                pl.light.intensity = l.lumens
                pl.light.attenuationRadius = max(10, l.y * 4)
                pl.position = SIMD3(l.x, l.y, l.z)
                root.addChild(pl)
                let face = WorldPrimitives.emissive(SIMD3(0.42, 0.14, 0.3), color, intensity: 5)
                face.position = SIMD3(l.x, l.y + 0.05, l.z)
                root.addChild(face)
                if kind.contains("bay") || kind.contains("window") || kind.contains("interior") || kind.contains("porch") {
                    daylight.addLamp(pl, face: face, faceColor: color, faceIntensity: 5)
                } else {
                    daylight.addStreetLight(pl, face: face, faceColor: color, faceIntensity: 5)
                }
            }
        }
    }

    /// Street furniture too small for a kit piece. The hydrant is one of the
    /// site's few allowed splashes of colour.
    private static func primitive(_ kind: String, scale: Float) -> Entity? {
        let k = kind.lowercased()
        let root = Entity()
        func add(_ e: Entity) { root.addChild(e) }
        switch k {
        case "bollard":
            let post = WorldPrimitives.box(SIMD3(0.16, 0.9, 0.16), NSColor(white: 0.45, alpha: 1), roughness: 0.7, corner: 0.03)
            add(post)
            let band = WorldPrimitives.box(SIMD3(0.17, 0.08, 0.17), NSColor(white: 0.75, alpha: 1), roughness: 0.6, corner: 0.02)
            band.position = SIMD3(0, 0.7, 0)
            add(band)
        case "hydrant":
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: NSColor(red: 0.85, green: 0.16, blue: 0.14, alpha: 1)); m.roughness = .init(floatLiteral: 0.5)
            let body = ModelEntity(mesh: .generateCylinder(height: 0.7, radius: 0.12), materials: [m]); body.position.y = 0.35; add(body)
            let cap = ModelEntity(mesh: .generateSphere(radius: 0.13), materials: [m]); cap.position.y = 0.72; add(cap)
            let arm = ModelEntity(mesh: .generateCylinder(height: 0.36, radius: 0.06), materials: [m])
            arm.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)); arm.position.y = 0.45; add(arm)
        case "drain":
            let g = WorldPrimitives.box(SIMD3(0.6, 0.02, 0.35), NSColor(white: 0.12, alpha: 1), roughness: 0.9, corner: 0)
            g.position = SIMD3(0, 0.005, 0); add(g)
            for i in 0..<5 {
                let slot = WorldPrimitives.box(SIMD3(0.5, 0.005, 0.03), NSColor(white: 0.03, alpha: 1), roughness: 1, corner: 0)
                slot.position = SIMD3(0, 0.026, -0.12 + Float(i) * 0.06); add(slot)
            }
        case "manhole":
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: NSColor(white: 0.22, alpha: 1)); m.roughness = .init(floatLiteral: 0.8)
            let d = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: 0.4), materials: [m]); d.position.y = 0.01; add(d)
        case "puddle", "puddles":
            add(WorldYard.puddle(2.2 * scale, 1.4 * scale, at: SIMD3(0, 0.001, 0), yaw: 0))
        case "tyre", "tyres":
            add(WorldYard.tyre(at: .zero))
            if k == "tyres" { add(WorldYard.tyre(at: SIMD3(0.5, 0, 0.3))); let t = WorldYard.tyre(at: SIMD3(0.2, 0.22, 0.15)); add(t) }
        case "kerb", "curb":
            let c = WorldPrimitives.box(SIMD3(3 * scale, 0.15, 0.25), NSColor(white: 0.55, alpha: 1), roughness: 1, corner: 0.01)
            add(c)
        default:
            return nil
        }
        return root
    }

    private static func color(for spec: String, kind: String) -> NSColor {
        let s = spec.lowercased()
        if s.hasPrefix("#"), s.count == 7, let v = UInt32(s.dropFirst(), radix: 16) {
            return NSColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        if s.contains("sodium") || s.contains("orange") || s.contains("amber") { return WorldYard.sodium }
        if s.contains("cold") || s.contains("led") || s.contains("blue") || s.contains("white") { return NSColor(red: 0.78, green: 0.86, blue: 1.0, alpha: 1) }
        if s.contains("warm") || s.contains("yellow") { return WorldYard.bayWarm }
        if s.contains("red") { return NSColor(red: 1.0, green: 0.3, blue: 0.2, alpha: 1) }
        if s.contains("green") { return NSColor(red: 0.4, green: 1.0, blue: 0.5, alpha: 1) }
        let k = kind.lowercased()
        if k.contains("sodium") { return WorldYard.sodium }
        return NSColor(red: 0.78, green: 0.86, blue: 1.0, alpha: 1)
    }
}
