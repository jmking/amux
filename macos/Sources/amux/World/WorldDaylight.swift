import RealityKit
import AppKit
import simd

// MARK: - Time of day
//
// Everything in the scene that changes with the hour lives here: the sun and
// moon, the sky dome and the image-based light built from it, the room's own
// lamps, the neon, the window glass, the street lights outside. The room and
// the yard register their lights as they are built; each frame the scene asks
// this to apply an hour, and the schedule below is interpolated to drive them.
//
// The hour is the user's clock by default, or whatever the toolbar's slider
// says. Lamps and street lights switch on the sun's elevation rather than the
// clock, so they come on over a few minutes at dusk instead of fading all
// afternoon, and dawn undoes them the same way.

@MainActor
final class WorldDaylight {

    /// One point on the day. Fields interpolate linearly between keys.
    struct Key {
        var hour: Float
        var sunElevation: Float          // degrees above the horizon
        var sunAzimuth: Float            // 0 = light from +z (camera side), 90 from +x, 180 from behind the back wall, 270 through the windows
        var sunColor: SIMD3<Float>
        var sunLux: Float
        var moonLux: Float
        var zenith: SIMD3<Float>
        var horizon: SIMD3<Float>
        var ground: SIMD3<Float>
        var ibl: Float                   // image-based light exponent
        var fillLux: Float               // soft shadowless fill from the camera's side
    }

    /// The day, from midnight to midnight. The sun rises through the windows
    /// (-x), crosses over the back wall and sets on the camera's side, so the
    /// viewer gets morning stripes on the floor and long warm light at the end.
    static let keys: [Key] = [
        Key(hour: 0,    sunElevation: -30, sunAzimuth: 0,   sunColor: [1, 1, 1],            sunLux: 0,     moonLux: 1500,
            zenith: [0.06, 0.08, 0.16], horizon: [0.04, 0.05, 0.09], ground: [0.03, 0.03, 0.04], ibl: 1.0,  fillLux: 300),
        Key(hour: 5,    sunElevation: -10, sunAzimuth: 275, sunColor: [1, 0.7, 0.5],        sunLux: 0,     moonLux: 1100,
            zenith: [0.10, 0.12, 0.24], horizon: [0.20, 0.13, 0.17], ground: [0.04, 0.04, 0.05], ibl: 1.1,  fillLux: 400),
        Key(hour: 6.25, sunElevation: 2,   sunAzimuth: 270, sunColor: [1, 0.6, 0.35],       sunLux: 2500,  moonLux: 0,
            zenith: [0.35, 0.40, 0.65], horizon: [0.95, 0.55, 0.35], ground: [0.25, 0.20, 0.18], ibl: 1.4,  fillLux: 800),
        Key(hour: 7.5,  sunElevation: 15,  sunAzimuth: 255, sunColor: [1, 0.8, 0.6],        sunLux: 6000,  moonLux: 0,
            zenith: [0.45, 0.62, 0.90], horizon: [0.85, 0.75, 0.65], ground: [0.35, 0.33, 0.30], ibl: 1.7,  fillLux: 1500),
        Key(hour: 10,   sunElevation: 40,  sunAzimuth: 225, sunColor: [1, 0.95, 0.88],      sunLux: 9000,  moonLux: 0,
            zenith: [0.40, 0.62, 0.95], horizon: [0.75, 0.82, 0.92], ground: [0.40, 0.40, 0.38], ibl: 1.9,  fillLux: 2200),
        Key(hour: 13,   sunElevation: 58,  sunAzimuth: 180, sunColor: [1, 0.98, 0.95],      sunLux: 10000, moonLux: 0,
            zenith: [0.35, 0.58, 0.95], horizon: [0.72, 0.80, 0.90], ground: [0.42, 0.42, 0.40], ibl: 2.0,  fillLux: 2600),
        Key(hour: 16,   sunElevation: 35,  sunAzimuth: 110, sunColor: [1, 0.9, 0.75],       sunLux: 8000,  moonLux: 0,
            zenith: [0.40, 0.58, 0.90], horizon: [0.85, 0.75, 0.60], ground: [0.40, 0.38, 0.34], ibl: 1.8,  fillLux: 2000),
        Key(hour: 18,   sunElevation: 8,   sunAzimuth: 60,  sunColor: [1, 0.62, 0.35],      sunLux: 4000,  moonLux: 0,
            zenith: [0.35, 0.35, 0.60], horizon: [0.95, 0.50, 0.30], ground: [0.30, 0.22, 0.18], ibl: 1.4,  fillLux: 1000),
        Key(hour: 19,   sunElevation: -3,  sunAzimuth: 45,  sunColor: [0.9, 0.5, 0.4],      sunLux: 500,   moonLux: 300,
            zenith: [0.15, 0.15, 0.35], horizon: [0.50, 0.28, 0.30], ground: [0.10, 0.08, 0.09], ibl: 1.2,  fillLux: 500),
        Key(hour: 20.5, sunElevation: -15, sunAzimuth: 30,  sunColor: [1, 1, 1],            sunLux: 0,     moonLux: 900,
            zenith: [0.08, 0.09, 0.20], horizon: [0.12, 0.09, 0.15], ground: [0.04, 0.04, 0.05], ibl: 1.05, fillLux: 350),
        Key(hour: 24,   sunElevation: -30, sunAzimuth: 0,   sunColor: [1, 1, 1],            sunLux: 0,     moonLux: 1500,
            zenith: [0.06, 0.08, 0.16], horizon: [0.04, 0.05, 0.09], ground: [0.03, 0.03, 0.04], ibl: 1.0,  fillLux: 300),
    ]

    static func sample(_ hour: Float) -> Key {
        let h = ((hour.truncatingRemainder(dividingBy: 24)) + 24).truncatingRemainder(dividingBy: 24)
        var a = keys[0], b = keys[keys.count - 1]
        for i in 0..<(keys.count - 1) where keys[i].hour <= h && h <= keys[i + 1].hour {
            a = keys[i]; b = keys[i + 1]; break
        }
        let span = max(0.001, b.hour - a.hour)
        let t = (h - a.hour) / span
        func L(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        func V(_ x: SIMD3<Float>, _ y: SIMD3<Float>) -> SIMD3<Float> { x + (y - x) * t }
        // azimuth through the shortest way round
        var da = b.sunAzimuth - a.sunAzimuth
        if da > 180 { da -= 360 } else if da < -180 { da += 360 }
        return Key(hour: h,
                   sunElevation: L(a.sunElevation, b.sunElevation),
                   sunAzimuth: a.sunAzimuth + da * t,
                   sunColor: V(a.sunColor, b.sunColor), sunLux: L(a.sunLux, b.sunLux), moonLux: L(a.moonLux, b.moonLux),
                   zenith: V(a.zenith, b.zenith), horizon: V(a.horizon, b.horizon), ground: V(a.ground, b.ground),
                   ibl: L(a.ibl, b.ibl), fillLux: L(a.fillLux, b.fillLux))
    }

    /// 1 below `on`, 0 above `off`, smooth between: the switch for things that
    /// respond to darkness.
    static func darkness(_ elevation: Float, on: Float, off: Float) -> Float {
        let t = min(1, max(0, (elevation - on) / (off - on)))
        return 1 - t * t * (3 - 2 * t)
    }

    // MARK: what is driven

    let sun = DirectionalLight()
    let moon = DirectionalLight()
    let fill = DirectionalLight()
    /// Registered lights as (full intensity, setter), so point and spot lights
    /// are driven alike; faces are the emissive bits that glow with them.
    private var lamps: [(Float, (Float) -> Void)] = []
    private var lampFaces: [(ModelEntity, NSColor, Float)] = []
    private var neonLights: [(Float, (Float) -> Void)] = []
    private var streetLights: [(Float, (Float) -> Void)] = []
    private var streetFaces: [(ModelEntity, NSColor, Float)] = []
    private var windows: [ModelEntity] = []
    var sky: ModelEntity?
    weak var renderer: RealityRenderer?

    /// The neon's level for the hour, which the scene's flicker multiplies.
    private(set) var neonLevel: Float = 1
    /// How dark it is outside, 0 in daylight and 1 at night.
    private(set) var night: Float = 1

    init() {
        sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 40, depthBias: 2)
        moon.light.color = NSColor(red: 0.55, green: 0.65, blue: 0.95, alpha: 1)
        moon.look(at: .zero, from: SIMD3(-20, 30, 12), relativeTo: nil)
        fill.light.color = NSColor(red: 0.6, green: 0.66, blue: 0.82, alpha: 1)
        fill.look(at: .zero, from: SIMD3(9, 9, 9), relativeTo: nil)
    }

    func install(under root: Entity) {
        root.addChild(sun)
        root.addChild(moon)
        root.addChild(fill)
    }

    func addLamp(_ light: PointLight, face: ModelEntity? = nil, faceColor: NSColor = .white, faceIntensity: Float = 6) {
        lamps.append((light.light.intensity, { light.light.intensity = $0 }))
        if let face { lampFaces.append((face, faceColor, faceIntensity)) }
    }
    func addNeon(_ light: PointLight) { neonLights.append((light.light.intensity, { light.light.intensity = $0 })) }
    func addStreetLight(_ light: PointLight, face: ModelEntity? = nil, faceColor: NSColor = .white, faceIntensity: Float = 5) {
        streetLights.append((light.light.intensity, { light.light.intensity = $0 }))
        if let face { streetFaces.append((face, faceColor, faceIntensity)) }
    }
    func addStreetLight(_ light: SpotLight) {
        streetLights.append((light.light.intensity, { light.light.intensity = $0 }))
    }
    func addWindow(_ glass: ModelEntity) { windows.append(glass) }

    // MARK: applying an hour

    private var lastSkyKey: SIMD3<Float>?
    private var lastSkyAt: CFAbsoluteTime = 0
    private var skyTask: Task<Void, Never>?

    func apply(hour: Float) {
        let k = Self.sample(hour)
        let e = k.sunElevation

        // sun and moon
        let az = k.sunAzimuth * .pi / 180, el = max(-89, e) * .pi / 180
        let from = SIMD3(sin(az) * cos(el), sin(el), cos(az) * cos(el)) * 60
        sun.look(at: .zero, from: from, relativeTo: nil)
        sun.light.color = nsColor(k.sunColor)
        sun.light.intensity = e > -6 ? k.sunLux : 0
        sun.isEnabled = sun.light.intensity > 0
        moon.light.intensity = k.moonLux
        moon.isEnabled = k.moonLux > 0
        fill.light.intensity = k.fillLux
        renderer?.lighting.intensityExponent = k.ibl

        // the switches: darkness by elevation, each with its own threshold
        let lampLevel = Self.darkness(e, on: 4, off: 12)
        let streetLevel = Self.darkness(e, on: 0, off: 6)
        neonLevel = Self.darkness(e, on: 5, off: 15)
        night = Self.darkness(e, on: -6, off: 8)

        for (full, set) in lamps { set(full * (0.08 + 0.92 * lampLevel)) }
        for (m, c, i) in lampFaces { setEmissive(m, c, i * (0.05 + 0.95 * lampLevel)) }
        for (full, set) in neonLights { set(full * neonLevel) }
        for (full, set) in streetLights { set(full * streetLevel) }
        for (m, c, i) in streetFaces { setEmissive(m, c, max(0.05, i * streetLevel)) }

        // the glass shows the sky by day and the yard's cold light by night
        let dayGlass = k.horizon * 1.3
        let nightGlass = SIMD3<Float>(0.16, 0.24, 0.40)
        let glass = nightGlass * night + dayGlass * (1 - night)
        for w in windows { setEmissive(w, nsColor(glass), 1.2 + 1.5 * (1 - night)) }

        // the sky is a texture; rebuild it when it has changed enough, and not
        // more than a few times a second while the slider is dragged
        let now = CFAbsoluteTimeGetCurrent()
        if lastSkyKey.map({ simd_length($0 - k.zenith - k.horizon) > 0.015 }) ?? true, now - lastSkyAt > 0.3, skyTask == nil {
            lastSkyKey = k.zenith + k.horizon
            lastSkyAt = now
            skyTask = Task { [weak self] in
                await self?.rebuildSky(zenith: k.zenith, horizon: k.horizon, ground: k.ground)
                self?.skyTask = nil
            }
        }
    }

    private func rebuildSky(zenith: SIMD3<Float>, horizon: SIMD3<Float>, ground: SIMD3<Float>) async {
        guard let img = WorldRoom.skyImage(zenith: zenith, horizon: horizon, ground: ground) else { return }
        if let tex = try? await TextureResource(image: img, options: .init(semantic: .color)), let sky {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(tex))
            m.faceCulling = .front
            sky.model?.materials = [m]
        }
        if let env = try? await EnvironmentResource(equirectangular: img) {
            renderer?.lighting.resource = env
        }
    }

    private func setEmissive(_ m: ModelEntity, _ color: NSColor, _ intensity: Float) {
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: .black)
        mat.emissiveColor = .init(color: color)
        mat.emissiveIntensity = intensity
        m.model?.materials = [mat]
    }

    private func nsColor(_ v: SIMD3<Float>) -> NSColor {
        NSColor(red: CGFloat(v.x), green: CGFloat(v.y), blue: CGFloat(v.z), alpha: 1)
    }
}
