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
    /// (-x), climbs over the camera's shoulder at noon so the walls the viewer
    /// looks at are lit, and sets on the far side (+x) with long light raking
    /// across the floor. Night is flat from 22:00 to 04:30 so nothing drifts.
    static let keys: [Key] = [
        Key(hour: 0, sunElevation: -45, sunAzimuth: 200, sunColor: [0.55, 0.65, 0.95], sunLux: 0, moonLux: 200,
            zenith: [0.05, 0.06, 0.13], horizon: [0.1, 0.1, 0.16], ground: [0.03, 0.03, 0.04], ibl: 1.6, fillLux: 110),
        Key(hour: 4.5, sunElevation: -20, sunAzimuth: 250, sunColor: [0.55, 0.65, 0.95], sunLux: 0, moonLux: 200,
            zenith: [0.05, 0.06, 0.13], horizon: [0.1, 0.1, 0.16], ground: [0.03, 0.03, 0.04], ibl: 1.6, fillLux: 110),
        Key(hour: 5.5, sunElevation: -6, sunAzimuth: 262, sunColor: [1, 0.55, 0.35], sunLux: 0, moonLux: 350,
            zenith: [0.12, 0.15, 0.3], horizon: [0.55, 0.34, 0.3], ground: [0.08, 0.07, 0.08], ibl: 1.4, fillLux: 500),
        Key(hour: 6.25, sunElevation: 2.5, sunAzimuth: 264, sunColor: [1, 0.52, 0.28], sunLux: 1800, moonLux: 0,
            zenith: [0.22, 0.32, 0.62], horizon: [1, 0.68, 0.42], ground: [0.14, 0.12, 0.11], ibl: 1.5, fillLux: 1200),
        Key(hour: 6.75, sunElevation: 8, sunAzimuth: 270, sunColor: [1, 0.7, 0.45], sunLux: 4500, moonLux: 0,
            zenith: [0.28, 0.42, 0.78], horizon: [0.95, 0.78, 0.58], ground: [0.18, 0.17, 0.16], ibl: 1.6, fillLux: 1400),
        Key(hour: 7.5, sunElevation: 16, sunAzimuth: 278, sunColor: [1, 0.82, 0.62], sunLux: 7000, moonLux: 0,
            zenith: [0.32, 0.52, 0.9], horizon: [0.8, 0.85, 0.9], ground: [0.24, 0.24, 0.23], ibl: 1.72, fillLux: 1700),
        Key(hour: 9.5, sunElevation: 38, sunAzimuth: 302, sunColor: [1, 0.93, 0.85], sunLux: 9500, moonLux: 0,
            zenith: [0.3, 0.52, 0.94], horizon: [0.78, 0.86, 0.92], ground: [0.28, 0.28, 0.27], ibl: 1.85, fillLux: 2200),
        Key(hour: 12, sunElevation: 63, sunAzimuth: 356, sunColor: [1, 0.98, 0.94], sunLux: 11000, moonLux: 0,
            zenith: [0.3, 0.5, 0.96], horizon: [0.8, 0.86, 0.9], ground: [0.3, 0.3, 0.29], ibl: 1.95, fillLux: 2600),
        Key(hour: 15, sunElevation: 45, sunAzimuth: 40, sunColor: [1, 0.95, 0.86], sunLux: 9800, moonLux: 0,
            zenith: [0.3, 0.48, 0.9], horizon: [0.82, 0.84, 0.86], ground: [0.28, 0.28, 0.27], ibl: 1.85, fillLux: 2200),
        Key(hour: 17.5, sunElevation: 18, sunAzimuth: 62, sunColor: [1, 0.74, 0.45], sunLux: 6500, moonLux: 0,
            zenith: [0.3, 0.44, 0.8], horizon: [0.96, 0.74, 0.48], ground: [0.24, 0.22, 0.2], ibl: 1.65, fillLux: 1600),
        Key(hour: 18.75, sunElevation: 8, sunAzimuth: 78, sunColor: [1, 0.6, 0.32], sunLux: 3800, moonLux: 0,
            zenith: [0.24, 0.3, 0.62], horizon: [1, 0.55, 0.32], ground: [0.16, 0.13, 0.12], ibl: 1.5, fillLux: 1300),
        Key(hour: 19.25, sunElevation: 4, sunAzimuth: 85, sunColor: [1, 0.48, 0.25], sunLux: 2000, moonLux: 0,
            zenith: [0.18, 0.22, 0.5], horizon: [1, 0.42, 0.22], ground: [0.1, 0.08, 0.09], ibl: 1.45, fillLux: 1200),
        Key(hour: 19.75, sunElevation: 1.5, sunAzimuth: 90, sunColor: [0.95, 0.38, 0.2], sunLux: 450, moonLux: 0,
            zenith: [0.12, 0.14, 0.36], horizon: [0.85, 0.32, 0.2], ground: [0.07, 0.06, 0.07], ibl: 1.4, fillLux: 1100),
        Key(hour: 20.5, sunElevation: -6, sunAzimuth: 95, sunColor: [0.95, 0.38, 0.2], sunLux: 0, moonLux: 300,
            zenith: [0.07, 0.09, 0.26], horizon: [0.32, 0.22, 0.34], ground: [0.05, 0.04, 0.06], ibl: 1.4, fillLux: 450),
        Key(hour: 22, sunElevation: -25, sunAzimuth: 120, sunColor: [0.55, 0.65, 0.95], sunLux: 0, moonLux: 200,
            zenith: [0.05, 0.06, 0.13], horizon: [0.1, 0.1, 0.16], ground: [0.03, 0.03, 0.04], ibl: 1.6, fillLux: 110),
        Key(hour: 24, sunElevation: -45, sunAzimuth: 200, sunColor: [0.55, 0.65, 0.95], sunLux: 0, moonLux: 200,
            zenith: [0.05, 0.06, 0.13], horizon: [0.1, 0.1, 0.16], ground: [0.03, 0.03, 0.04], ibl: 1.6, fillLux: 110),
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

    /// One shadow-casting light: the sun while it is up, the moon after. Two
    /// shadowing directional lights is the expensive case and they are never
    /// both needed.
    let sun = DirectionalLight()
    let fill = DirectionalLight()
    private let moonFrom = SIMD3<Float>(-8, 14, 6)
    private let moonColor = NSColor(red: 0.55, green: 0.65, blue: 0.95, alpha: 1)
    /// Registered lights as (full intensity, setter), so point and spot lights
    /// are driven alike; faces are the emissive bits that glow with them.
    private var lamps: [(Float, (Float) -> Void)] = []
    private var lampFaces: [(ModelEntity, NSColor, Float, NSColor)] = []   // face, glow colour, glow, day colour
    private var neonLights: [(Float, (Float) -> Void)] = []
    private var streetLights: [(Float, (Float) -> Void)] = []
    private var streetFaces: [(ModelEntity, NSColor, Float)] = []
    var sky: ModelEntity?
    weak var renderer: RealityRenderer?

    /// The neon's level for the hour, which the scene's flicker multiplies.
    private(set) var neonLevel: Float = 1
    /// How dark it is outside, 0 in daylight and 1 at night.
    private(set) var night: Float = 1
    /// Whether the street lights are on, for things that blink with them.
    private(set) var streetLevel: Float = 1

    init() {
        // the camera is 90 m out, so the shadow range has to reach past it
        sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 130, depthBias: 2)
        fill.light.color = NSColor(red: 0.6, green: 0.66, blue: 0.82, alpha: 1)
        fill.look(at: .zero, from: SIMD3(9, 9, 9), relativeTo: nil)
    }

    func install(under root: Entity) {
        root.addChild(sun)
        root.addChild(fill)
    }

    func addLamp(_ light: PointLight, face: ModelEntity? = nil, faceColor: NSColor = .white, faceIntensity: Float = 6) {
        lamps.append((light.light.intensity, { light.light.intensity = $0 }))
        if let face { lampFaces.append((face, faceColor, faceIntensity, .black)) }
    }
    func addLamp(_ light: SpotLight) { lamps.append((light.light.intensity, { light.light.intensity = $0 })) }
    /// `dayColor` is what the face looks like unlit; a shade stays cream by day
    /// rather than going black like a bulb.
    func addLampFace(_ face: ModelEntity, color: NSColor, intensity: Float, dayColor: NSColor = .black) { lampFaces.append((face, color, intensity, dayColor)) }
    func addStreetFace(_ face: ModelEntity, color: NSColor, intensity: Float) { streetFaces.append((face, color, intensity)) }
    func addNeon(_ light: PointLight) { neonLights.append((light.light.intensity, { light.light.intensity = $0 })) }
    func addStreetLight(_ light: PointLight, face: ModelEntity? = nil, faceColor: NSColor = .white, faceIntensity: Float = 5) {
        streetLights.append((light.light.intensity, { light.light.intensity = $0 }))
        if let face { streetFaces.append((face, faceColor, faceIntensity)) }
    }
    func addStreetLight(_ light: SpotLight) {
        streetLights.append((light.light.intensity, { light.light.intensity = $0 }))
    }

    // MARK: applying an hour

    private var lastSkyKey: SIMD3<Float>?
    private var lastSkyAt: CFAbsoluteTime = 0
    private var skyTask: Task<Void, Never>?
    private var lastHour: Float = .nan
    private var appliedLampLevel: Float = .nan
    private var appliedStreetLevel: Float = .nan
    private var appliedNight: Float = .nan

    func apply(hour: Float) {
        // the clock moves once a minute and the slider in small steps; nothing
        // below is cheap enough to redo every frame for an unchanged hour.
        // Reassigning a material is the expensive part: RealityKit binds its
        // parameters by string hashing, and twenty faces at 30 fps was most of
        // a core.
        if abs(hour - lastHour) < 0.001 { return }
        lastHour = hour
        let k = Self.sample(hour)
        let e = k.sunElevation

        // the key light: sun direction and colour while there is sun, the
        // moon's fixed place over the windows otherwise. Below 1.5 degrees the
        // sun is a disc on the horizon with no light worth casting.
        let sunLux: Float = e > 1.5 ? k.sunLux : 0
        if sunLux >= k.moonLux, sunLux > 0 {
            let az = k.sunAzimuth * .pi / 180, el = e * .pi / 180
            let from = SIMD3(sin(az) * cos(el), sin(el), cos(az) * cos(el)) * 60
            sun.look(at: .zero, from: from, relativeTo: nil)
            sun.light.color = nsColor(k.sunColor)
            sun.light.intensity = sunLux
        } else {
            sun.look(at: .zero, from: moonFrom * 4, relativeTo: nil)
            sun.light.color = moonColor
            sun.light.intensity = k.moonLux
        }
        sun.isEnabled = sun.light.intensity > 0
        fill.light.intensity = k.fillLux
        renderer?.lighting.intensityExponent = k.ibl

        // the switches: darkness by elevation, each with its own threshold.
        // Dusk is layered: pendants first, neon to full, then the street
        // lights while the sun is still a disc; morning unwinds it in reverse.
        let lampLevel = Self.darkness(e, on: 8, off: 14)
        streetLevel = Self.darkness(e, on: 3, off: 7)
        neonLevel = 0.25 + 0.75 * Self.darkness(e, on: 8, off: 16)
        night = Self.darkness(e, on: -6, off: 8)

        for (full, set) in lamps { set(full * (0.08 + 0.92 * lampLevel)) }
        for (full, set) in neonLights { set(full * neonLevel) }
        for (full, set) in streetLights { set(full * streetLevel) }
        if abs(lampLevel - appliedLampLevel) > 0.01 || appliedLampLevel.isNaN {
            appliedLampLevel = lampLevel
            for (m, c, i, day) in lampFaces { setEmissive(m, c, i * (0.05 + 0.95 * lampLevel), base: day) }
        }
        if abs(streetLevel - appliedStreetLevel) > 0.01 || appliedStreetLevel.isNaN {
            appliedStreetLevel = streetLevel
            for (m, c, i) in streetFaces { setEmissive(m, c, max(0.05, i * streetLevel)) }
        }

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

    private func setEmissive(_ m: ModelEntity, _ color: NSColor, _ intensity: Float, base: NSColor = .black) {
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: base)
        mat.roughness = .init(floatLiteral: 1)
        mat.emissiveColor = .init(color: color)
        mat.emissiveIntensity = intensity
        m.model?.materials = [mat]
    }

    private func nsColor(_ v: SIMD3<Float>) -> NSColor {
        NSColor(red: CGFloat(v.x), green: CGFloat(v.y), blue: CGFloat(v.z), alpha: 1)
    }
}
