import RealityKit
import AppKit
import simd

// MARK: - One agent in the room
//
// An actor is spawned outside the door when its agent appears, walks in and
// takes a seat, animates from the agent's phase while it lives, and walks out
// again when the agent goes. Its look comes from the rigged hoodie character
// when the model is available and from a primitive figure otherwise; either way
// the choreography (paths, seats, timing) is the same, which is what lets it be
// tested without the art.
//
// Animation, for the rigged model:
//  - standing and walking play clips (idle, walk) cross-faded on the rig
//  - reactions play one-shot clips (wave, hit)
//  - sitting, typing, thinking and the rest are POSED: no CC0 clip exists for
//    them, so the skeleton's joints are driven in code from a base pose, eased
//    every frame so changes read as movement rather than snaps
// The primitive figure has the same states, posed on its named parts.

enum WorldReaction { case message, done }

struct WorldPhaseStyle {
    static func color(_ p: AgentPhase) -> NSColor {
        switch p {
        case .thinking: return NSColor(red: 0.72, green: 0.55, blue: 1.0, alpha: 1)
        case .tool: return NSColor(red: 0.35, green: 0.9, blue: 0.5, alpha: 1)
        case .network: return NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1)
        case .waiting: return NSColor(red: 1.0, green: 0.72, blue: 0.25, alpha: 1)
        case .done: return NSColor(red: 0.3, green: 0.9, blue: 0.85, alpha: 1)
        case .idle: return NSColor(white: 0.55, alpha: 1)
        }
    }
}

@MainActor
final class WorldActor {
    let paneId: String
    let kind: String
    let color: NSColor
    let entity = Entity()
    private(set) var label: String
    private(set) var phase: AgentPhase = .idle
    private(set) var seat: WorldSeat?
    private(set) var seatIndex: Int?
    /// Fired when the actor crosses the threshold, so the door can swing.
    var onDoor: (() -> Void)?

    private enum Mode { case walking, seated, standing, gone }
    private var mode: Mode = .standing
    private var path: [SIMD3<Float>] = []
    private var onArrive: (() -> Void)?
    private var leaving = false
    private var yaw: Float = 0
    private var targetYaw: Float = 0

    private var clock: Float = 0
    private var reaction: (kind: WorldReaction, until: Float)?

    // presentation
    private let figure: Entity
    private let tag = Entity()
    private var tagLabel: ModelEntity?
    private var tagSpec: WorldLabel.Spec?
    private let marker = Entity()
    private var markerLabel: ModelEntity?
    private var markerKind: String?

    // rigged model
    private let clips: [String: AnimationResource]
    private var skins: [ModelEntity] = []
    private var jointIndex: [String: Int] = [:]
    private var basePose: [Transform]?
    private var currentClip: String?
    private var oneShotUntil: Float = 0
    /// The model's origin sits on the floor; sitting drops it onto the chair.
    private var figureDrop: Float = 0

    // primitive figure
    private var joints: [String: Entity] = [:]
    private var isRigged: Bool { !skins.isEmpty }

    var isGone: Bool { mode == .gone }
    var position: SIMD3<Float> { entity.position }

    init(paneId: String, label: String, kind: String, model: Entity?, clips: [String: AnimationResource] = [:]) {
        self.paneId = paneId
        self.label = label
        self.kind = kind
        self.clips = clips
        let brand = AgentBrand.of(kind).color
        color = NSColor(red: CGFloat((brand >> 16) & 0xff) / 255,
                        green: CGFloat((brand >> 8) & 0xff) / 255,
                        blue: CGFloat(brand & 0xff) / 255, alpha: 1)
        entity.name = "actor:" + paneId

        if let model {
            figure = model
            // the pack's character is authored 1.5x life size; the room is in metres
            figure.scale = SIMD3(repeating: 0.66)
            func walk(_ e: Entity) {
                if let me = e as? ModelEntity, !me.jointNames.isEmpty { skins.append(me) }
                for c in e.children { walk(c) }
            }
            walk(model)
            if let first = skins.first {
                for (i, name) in first.jointNames.enumerated() {
                    // "Root/Body/Hips/Abdomen" -> "Abdomen"
                    let leaf = name.split(separator: "/").last.map(String.init) ?? name
                    jointIndex[leaf] = i
                }
            }
            Self.recolour(model, hoodie: color)
        } else {
            figure = WorldPrimitives.figure(hoodie: color)
            for name in ["hips", "legL", "legR", "armL", "armR", "neck", "torso", "head"] {
                if let j = figure.findEntity(named: name) { joints[name] = j }
            }
        }
        entity.addChild(figure)
        buildTag()
        buildMarker()
        entity.isEnabled = false
    }

    /// Tints whatever in a loaded model looks like the hoodie: the converter
    /// names that material "Hoodie"; other packs are matched loosely, and a
    /// model with no such name gets its largest single-material mesh tinted.
    private static func recolour(_ model: Entity, hoodie: NSColor) {
        var best: (ModelEntity, Int)?
        var hitAny = false
        func walk(_ e: Entity) {
            if let me = e as? ModelEntity, var comp = me.model {
                var hit = false
                for (i, m) in comp.materials.enumerated() {
                    let n = String(describing: (m as? PhysicallyBasedMaterial)?.name ?? "").lowercased()
                    if n.contains("hood") || n.contains("torso") || n.contains("shirt") || n.contains("cloth") {
                        var pbr = PhysicallyBasedMaterial()
                        pbr.baseColor = .init(tint: hoodie)
                        pbr.roughness = .init(floatLiteral: 0.95)
                        comp.materials[i] = pbr
                        hit = true
                    }
                }
                if hit { me.model = comp; hitAny = true }
                let v = comp.mesh.contents.models.reduce(0) { $0 + $1.parts.reduce(0) { $0 + $1.positions.count } }
                if best == nil || v > best!.1 { best = (me, v) }
            }
            for c in e.children { walk(c) }
        }
        walk(model)
        if !hitAny, var comp = best?.0.model, comp.materials.count == 1 {
            var pbr = PhysicallyBasedMaterial()
            pbr.baseColor = .init(tint: hoodie)
            pbr.roughness = .init(floatLiteral: 0.95)
            comp.materials = [pbr]
            best?.0.model = comp
        }
    }

    // MARK: name tag and marker

    private func buildTag() {
        tag.name = "tag"
        tag.position = SIMD3(0, 2.0, 0)
        tag.components.set(BillboardComponent())
        entity.addChild(tag)
        refreshTag()
    }

    private func refreshTag() {
        let spec = WorldLabel.Spec(text: label, glyph: AgentBrand.of(kind).glyph, glyphColor: color,
                                   dot: WorldPhaseStyle.color(phase))
        guard spec != tagSpec else { return }
        tagSpec = spec
        Task { [weak self] in
            guard let self else { return }
            if let existing = self.tagLabel {
                await WorldLabel.update(existing, spec)
            } else if let made = await WorldLabel.make(spec) {
                self.tagLabel = made
                self.tag.addChild(made)
            }
        }
    }

    private func buildMarker() {
        marker.name = "marker"
        marker.position = SIMD3(0, 2.4, 0)
        marker.components.set(BillboardComponent())
        marker.isEnabled = false
        entity.addChild(marker)
    }

    private func showMarker(_ glyph: String?, color: NSColor) {
        guard markerKind != glyph else { return }
        markerKind = glyph
        guard let glyph else { marker.isEnabled = false; return }
        marker.isEnabled = true
        let spec = WorldLabel.Spec(text: glyph, textColor: color, background: nil, fontSize: 34, weight: .heavy)
        Task { [weak self] in
            guard let self else { return }
            if let existing = self.markerLabel {
                await WorldLabel.update(existing, spec)
            } else if let made = await WorldLabel.make(spec) {
                self.markerLabel = made
                self.marker.addChild(made)
            }
        }
    }

    // MARK: choreography

    func enter(from spawn: SIMD3<Float>, via threshold: SIMD3<Float>, to seat: WorldSeat?, index: Int?) {
        entity.position = spawn
        entity.isEnabled = true
        self.seat = seat
        self.seatIndex = index
        yaw = Self.yaw(from: spawn, to: threshold)
        targetYaw = yaw
        onDoor?()
        var waypoints = [threshold]
        if let seat {
            waypoints.append(seat.approach)
            waypoints.append(seat.position)
        }
        walk(waypoints) { [weak self] in
            guard let self else { return }
            if let seat = self.seat {
                self.targetYaw = seat.yaw
                self.mode = .seated
            } else {
                self.mode = .standing
            }
        }
    }

    func stand(at spot: SIMD3<Float>, from spawn: SIMD3<Float>, via threshold: SIMD3<Float>) {
        entity.position = spawn
        entity.isEnabled = true
        yaw = Self.yaw(from: spawn, to: threshold)
        targetYaw = yaw
        onDoor?()
        walk([threshold, spot]) { [weak self] in
            self?.mode = .standing
            self?.targetYaw = .pi * 0.75
        }
    }

    func leave(via threshold: SIMD3<Float>, to spawn: SIMD3<Float>) {
        guard !leaving else { return }
        leaving = true
        showMarker(nil, color: .white)
        var waypoints: [SIMD3<Float>] = []
        if let seat { waypoints.append(seat.approach) }
        waypoints.append(threshold)
        waypoints.append(spawn)
        walk(waypoints) { [weak self] in
            self?.mode = .gone
            self?.entity.isEnabled = false
        }
        // the door swings as they reach it
        let delay = Double(waypoints.dropLast().reduce((0, entity.position)) { acc, p in
            (acc.0 + simd_length(p - acc.1), p) }.0 / 1.6)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay - 0.4)))
            self?.onDoor?()
        }
    }

    private func walk(_ waypoints: [SIMD3<Float>], then: @escaping () -> Void) {
        path = waypoints
        onArrive = then
        mode = .walking
        basePose = nil
        play("walk")
    }

    func setPhase(_ p: AgentPhase) {
        guard p != phase else { return }
        let was = phase
        phase = p
        refreshTag()
        if p == .done, was != .done { react(.done) }
    }

    func setLabel(_ l: String) {
        guard l != label else { return }
        label = l
        refreshTag()
    }

    func react(_ kind: WorldReaction) {
        reaction = (kind, clock + (kind == .message ? 1.6 : 2.6))
        // standing figures can act it out with a clip; seated ones are posed
        if mode != .seated {
            if kind == .message { play("hit", once: true) }
            if kind == .done { play("wave", once: true) }
        }
    }

    // MARK: per frame

    func tick(dt: Float, cameraForward: SIMD3<Float>) {
        clock += dt
        if let r = reaction, clock > r.until { reaction = nil }
        if oneShotUntil > 0, clock > oneShotUntil { oneShotUntil = 0; currentClip = nil; applyClipForMode() }

        switch mode {
        case .walking:
            step(dt: dt)
        case .seated, .standing:
            if phase == .waiting, !leaving {
                // turn to the viewer: face against the camera's forward vector
                let f = -cameraForward
                targetYaw = atan2(f.x, f.z)
            } else if let seat, mode == .seated {
                targetYaw = seat.yaw
            }
        case .gone:
            return
        }

        // ease heading
        var d = targetYaw - yaw
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        yaw += d * min(1, dt * 9)
        entity.orientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))

        if isRigged { poseRig(dt: dt) } else { posePrimitive(dt: dt) }

        // marker above the head
        switch (reaction?.kind, phase) {
        case (.message?, _): showMarker("✉", color: NSColor(red: 0.5, green: 0.85, blue: 1, alpha: 1))
        case (_, .waiting) where !leaving: showMarker("?", color: WorldPhaseStyle.color(.waiting))
        default: showMarker(nil, color: .white)
        }
        if marker.isEnabled {
            marker.scale = SIMD3(repeating: 1 + sin(clock * 6) * 0.08)
            marker.position.y = 2.4 + sin(clock * 3) * 0.04
        }
    }

    private func step(dt: Float) {
        guard let next = path.first else { return }
        let here = entity.position
        let delta = next - here
        let dist = simd_length(SIMD3(delta.x, 0, delta.z))
        let speed: Float = 1.6
        if dist < speed * dt * 1.2 || dist < 0.02 {
            entity.position = next
            path.removeFirst()
            if path.isEmpty {
                mode = .standing
                onArrive?()
                onArrive = nil
                applyClipForMode()
            } else {
                targetYaw = Self.yaw(from: next, to: path[0])
            }
            return
        }
        targetYaw = Self.yaw(from: here, to: next)
        let dir = SIMD3(delta.x, 0, delta.z) / dist
        entity.position = here + dir * speed * dt
    }

    private static func yaw(from a: SIMD3<Float>, to b: SIMD3<Float>) -> Float {
        let d = b - a
        return atan2(d.x, d.z)
    }

    // MARK: clips (rigged model)

    private func play(_ name: String, once: Bool = false) {
        guard isRigged, let clip = clips[name] else { return }
        if !once, currentClip == name { return }
        currentClip = name
        basePose = nil
        let res = once ? clip : clip.repeat()
        // the skeleton lives on the skinned entity; clips bind there
        (skins.first ?? figure).playAnimation(res, transitionDuration: 0.3, startsPaused: false)
        oneShotUntil = once ? clock + Float(clip.definition.duration) : 0
    }

    private func applyClipForMode() {
        guard isRigged else { return }
        switch mode {
        case .walking: play("walk")
        case .standing: play("idle")
        case .seated, .gone: break   // posed, not played
        }
    }

    // MARK: procedural posing (rigged model)
    //
    // A seated figure is driven entirely from here. The base pose is whatever
    // the rig was doing when it sat down (the tail of the idle clip), and each
    // state is a set of joint rotations layered on it. Joint axes follow the
    // model's bones: X bends forward, Z swings sideways, Y twists.

    private func poseRig(dt: Float) {
        // the model's origin drops onto the chair when seated
        let dropTarget: Float = mode == .seated ? -0.30 : 0
        figureDrop += (dropTarget - figureDrop) * min(1, dt * 8)
        figure.position.y = figureDrop

        guard mode == .seated, let host = skins.first else { return }
        if basePose == nil {
            basePose = host.jointTransforms
            figure.stopAllAnimations(recursive: true)
            currentClip = nil
        }
        guard let base = basePose else { return }
        var target = base
        let t = clock

        func rot(_ joint: String, x: Float = 0, y: Float = 0, z: Float = 0) {
            guard let i = jointIndex[joint], i < target.count else { return }
            let q = simd_quatf(angle: x, axis: SIMD3(1, 0, 0))
                * simd_quatf(angle: y, axis: SIMD3(0, 1, 0))
                * simd_quatf(angle: z, axis: SIMD3(0, 0, 1))
            target[i].rotation = base[i].rotation * q
        }

        // sitting: thighs forward, shins down
        rot("UpperLeg_L", x: 1.45)
        rot("UpperLeg_R", x: 1.45)
        rot("LowerLeg_L", x: 1.5)
        rot("LowerLeg_R", x: 1.5)
        let breathe = sin(t * 1.4) * 0.02

        switch phase {
        case .tool, .network:
            // hands on the keyboard, fingers going
            rot("UpperArm_L", x: 0.55, z: 0.15)
            rot("UpperArm_R", x: 0.55, z: -0.15)
            rot("LowerArm_L", x: 1.0 + sin(t * 11) * 0.06)
            rot("LowerArm_R", x: 1.0 + sin(t * 11 + 1.3) * 0.06)
            rot("Abdomen", x: 0.12 + breathe)
            rot("Head", x: 0.18)
        case .thinking:
            rot("Abdomen", x: -0.18 + breathe)
            rot("UpperArm_L", x: 0.5, z: 0.1)
            rot("LowerArm_L", x: 0.9)
            rot("UpperArm_R", x: 0.9, z: -0.35)
            rot("LowerArm_R", x: 2.35)
            rot("Head", x: -0.1, y: sin(t * 0.7) * 0.2, z: 0.12)
        case .waiting:
            rot("UpperArm_L", x: 0.5)
            rot("LowerArm_L", x: 0.9)
            rot("UpperArm_R", x: -2.6, z: -0.3)
            rot("LowerArm_R", x: 0.4 + sin(t * 7) * 0.25)
            rot("Head", x: -0.12)
        case .done:
            rot("Abdomen", x: -0.28 + breathe)
            rot("UpperArm_L", x: -2.5, z: 0.4)
            rot("UpperArm_R", x: -2.5, z: -0.4)
            rot("LowerArm_L", x: 0.3)
            rot("LowerArm_R", x: 0.3)
            rot("Head", x: -0.3)
        case .idle:
            rot("Abdomen", x: 0.22 + breathe)
            rot("Chest", x: 0.1)
            rot("UpperArm_L", x: 0.35, z: 0.1)
            rot("UpperArm_R", x: 0.35, z: -0.1)
            rot("LowerArm_L", x: 0.6)
            rot("LowerArm_R", x: 0.6)
            rot("Head", x: 0.08, y: sin(t * 0.45) * 0.4)
        }
        if reaction?.kind == .message {
            rot("Head", x: sin(t * 12) * 0.22)
        }
        if reaction?.kind == .done {
            rot("Abdomen", x: -0.28)
            rot("UpperArm_L", x: -2.5, z: 0.4)
            rot("UpperArm_R", x: -2.5, z: -0.4)
        }

        let ease = min(1, dt * 9)
        var cur = host.jointTransforms
        for i in cur.indices where i < target.count {
            cur[i].rotation = simd_slerp(cur[i].rotation, target[i].rotation, ease)
            cur[i].translation = target[i].translation
        }
        for s in skins { s.jointTransforms = cur }
    }

    // MARK: procedural posing (primitive figure)

    private func posePrimitive(dt: Float) {
        guard let hips = joints["hips"], let legL = joints["legL"], let legR = joints["legR"],
              let armL = joints["armL"], let armR = joints["armR"], let neck = joints["neck"] else { return }
        let t = clock
        var hipsY: Float = 0.92
        var hipsPitch: Float = 0
        var legs: (Float, Float) = (0, 0)
        var arms: (Float, Float) = (0, 0)
        var armsRoll: (Float, Float) = (0, 0)
        var neckPitch: Float = 0
        var neckYaw: Float = 0

        switch mode {
        case .walking:
            let s = sin(t * 9)
            legs = (s * 0.55, -s * 0.55)
            arms = (-s * 0.45, s * 0.45)
            hipsY = 0.92 + abs(cos(t * 9)) * 0.03
        case .seated:
            hipsY = 0.5
            legs = (-.pi / 2 + 0.1, -.pi / 2 + 0.1)
            switch phase {
            case .tool, .network:
                arms = (-1.15 + sin(t * 11) * 0.05, -1.15 + sin(t * 11 + 1.3) * 0.05)
                neckPitch = 0.12
            case .thinking:
                hipsPitch = -0.14
                arms = (-0.95, -2.35)
                armsRoll = (0, -0.35)
                neckPitch = -0.08
                neckYaw = sin(t * 0.7) * 0.15
            case .waiting:
                arms = (-0.6, .pi - 0.2 + sin(t * 7) * 0.12)
                armsRoll = (0, -0.25)
                neckPitch = -0.1
            case .done:
                hipsPitch = -0.2
                arms = (.pi - 0.35, .pi - 0.35)
                armsRoll = (0.35, -0.35)
                neckPitch = -0.25
            case .idle:
                hipsPitch = 0.12
                arms = (-0.25 + sin(t * 1.1) * 0.05, -0.25 + cos(t * 1.3) * 0.05)
                armsRoll = (0.12, -0.12)
                neckPitch = 0.05
                neckYaw = sin(t * 0.45) * 0.4
            }
        case .standing, .gone:
            arms = (sin(t * 1.2) * 0.05, cos(t * 1.1) * 0.05)
            armsRoll = (0.1, -0.1)
            hipsY = 0.92 + sin(t * 1.5) * 0.005
            if phase == .waiting { arms.1 = .pi - 0.2 + sin(t * 7) * 0.12; armsRoll.1 = -0.25 }
            neckYaw = sin(t * 0.4) * 0.3
        }
        if reaction?.kind == .message { neckPitch += sin(t * 12) * 0.22 }
        if reaction?.kind == .done, mode != .walking {
            hipsPitch = -0.22
            arms = (.pi - 0.3, .pi - 0.3)
            armsRoll = (0.4, -0.4)
        }

        let ease = min(1, dt * 10)
        func slerp(_ e: Entity, pitch: Float, roll: Float = 0, yawR: Float = 0) {
            let q = simd_quatf(angle: yawR, axis: SIMD3(0, 1, 0))
                * simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
                * simd_quatf(angle: roll, axis: SIMD3(0, 0, 1))
            e.orientation = simd_slerp(e.orientation, q, ease)
        }
        hips.position.y += (hipsY - hips.position.y) * ease
        slerp(hips, pitch: hipsPitch)
        slerp(legL, pitch: legs.0)
        slerp(legR, pitch: legs.1)
        slerp(armL, pitch: arms.0, roll: armsRoll.0)
        slerp(armR, pitch: arms.1, roll: armsRoll.1)
        slerp(neck, pitch: neckPitch, yawR: neckYaw)
    }
}
