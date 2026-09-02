import RealityKit
import AppKit
import simd

// MARK: - One agent in the room
//
// An actor is spawned outside the door when its agent appears, walks in and
// takes a seat, animates from the agent's phase while it lives, and walks out
// again when the agent goes.
//
// The figure is a blocky, Minecraft-proportioned character built from boxes
// (WorldPrimitives.figure): a hooded head, a torso in the agent's brand colour,
// straight limbs that pivot at the shoulder and hip. Every state is posed in
// code by rotating those parts towards a target pose and easing there each
// frame, so a change of state reads as movement rather than a snap.

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
    private var joints: [String: Entity] = [:]
    private let tag = Entity()
    private var tagLabel: ModelEntity?
    private var tagSpec: WorldLabel.Spec?
    private let marker = Entity()
    private var markerLabel: ModelEntity?
    private var markerKind: String?

    var isGone: Bool { mode == .gone }
    var position: SIMD3<Float> { entity.position }

    /// Figure heights, in metres: the hip pivot standing, and on a chair.
    private static let hipStanding = WorldPrimitives.figureHipHeight
    private static let hipSeated: Float = 0.47

    init(paneId: String, label: String, kind: String) {
        self.paneId = paneId
        self.label = label
        self.kind = kind
        let brand = AgentBrand.of(kind).color
        color = NSColor(red: CGFloat((brand >> 16) & 0xff) / 255,
                        green: CGFloat((brand >> 8) & 0xff) / 255,
                        blue: CGFloat(brand & 0xff) / 255, alpha: 1)
        entity.name = "actor:" + paneId

        // the same agent keeps the same face across launches
        let seed = paneId.utf8.reduce(5381) { ($0 &* 33) &+ Int($1) }
        figure = WorldPrimitives.figure(hoodie: color, seed: seed)
        for name in ["hips", "legL", "legR", "armL", "armR", "neck"] {
            if let j = figure.findEntity(named: name) { joints[name] = j }
        }
        entity.addChild(figure)
        buildTag()
        buildMarker()
        entity.isEnabled = false
    }

    // MARK: name tag and marker

    private func buildTag() {
        tag.name = "tag"
        tag.position = SIMD3(0, WorldPrimitives.figureHeight + 0.22, 0)
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
        marker.position = SIMD3(0, WorldPrimitives.figureHeight + 0.62, 0)
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
    }

    // MARK: per frame

    func tick(dt: Float, cameraForward: SIMD3<Float>) {
        clock += dt
        if let r = reaction, clock > r.until { reaction = nil }

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

        pose(dt: dt)

        // marker above the head
        switch (reaction?.kind, phase) {
        case (.message?, _): showMarker("✉", color: NSColor(red: 0.5, green: 0.85, blue: 1, alpha: 1))
        case (_, .waiting) where !leaving: showMarker("?", color: WorldPhaseStyle.color(.waiting))
        default: showMarker(nil, color: .white)
        }
        if marker.isEnabled {
            marker.scale = SIMD3(repeating: 1 + sin(clock * 6) * 0.08)
            marker.position.y = WorldPrimitives.figureHeight + 0.62 + sin(clock * 3) * 0.04
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

    // MARK: posing
    //
    // Limbs are straight and pivot at their top, as they do on the reference
    // figures: legs swing at the hip, arms at the shoulder, the head at the
    // neck. Angles are radians about the figure's X (forward bend), with a
    // little Z for arms held out to the side.

    private func pose(dt: Float) {
        guard let hips = joints["hips"], let legL = joints["legL"], let legR = joints["legR"],
              let armL = joints["armL"], let armR = joints["armR"], let neck = joints["neck"] else { return }
        let t = clock
        var hipsY = Self.hipStanding
        var hipsPitch: Float = 0
        var legs: (Float, Float) = (0, 0)
        var arms: (Float, Float) = (0, 0)
        var armsOut: (Float, Float) = (0, 0)
        var neckPitch: Float = 0
        var neckYaw: Float = 0
        let breathe = sin(t * 1.4) * 0.012

        switch mode {
        case .walking:
            let s = sin(t * 9)
            legs = (s * 0.7, -s * 0.7)
            arms = (-s * 0.6, s * 0.6)
            hipsY += abs(cos(t * 9)) * 0.035
            neckPitch = 0.04
        case .seated:
            hipsY = Self.hipSeated
            legs = (-.pi / 2 + 0.12, -.pi / 2 + 0.12)     // straight out, resting on the seat
            switch phase {
            case .tool, .network:
                // hands on the keyboard, a little busy
                arms = (-1.12 + sin(t * 11) * 0.06, -1.12 + sin(t * 11 + 1.3) * 0.06)
                neckPitch = 0.16 + breathe
            case .thinking:
                // leaning back, one hand up to the face, head wandering
                hipsPitch = -0.16
                arms = (-0.9, -2.55)
                armsOut = (0, -0.25)
                neckPitch = -0.1
                neckYaw = sin(t * 0.7) * 0.25
            case .waiting:
                // turned to the viewer, one arm up and waving
                arms = (-0.6, .pi - 0.25 + sin(t * 7) * 0.15)
                armsOut = (0, -0.35)
                neckPitch = -0.08
            case .done:
                // arms up
                hipsPitch = -0.2
                arms = (.pi - 0.4, .pi - 0.4)
                armsOut = (0.45, -0.45)
                neckPitch = -0.2
            case .idle:
                // slouched, hands in the pocket, looking around
                hipsPitch = 0.14 + breathe
                arms = (-0.35 + sin(t * 1.1) * 0.04, -0.35 + cos(t * 1.3) * 0.04)
                armsOut = (0.15, -0.15)
                neckPitch = 0.06
                neckYaw = sin(t * 0.45) * 0.5
            }
        case .standing, .gone:
            arms = (sin(t * 1.2) * 0.05, cos(t * 1.1) * 0.05)
            armsOut = (0.08, -0.08)
            hipsY += sin(t * 1.5) * 0.004
            if phase == .waiting { arms.1 = .pi - 0.25 + sin(t * 7) * 0.15; armsOut.1 = -0.35 }
            neckYaw = sin(t * 0.4) * 0.35
        }
        if reaction?.kind == .message { neckPitch += sin(t * 12) * 0.25 }   // a nod
        if reaction?.kind == .done, mode != .walking {
            hipsPitch = -0.22
            arms = (.pi - 0.35, .pi - 0.35)
            armsOut = (0.45, -0.45)
        }

        let ease = min(1, dt * 10)
        func turn(_ e: Entity, pitch: Float, out: Float = 0, yawR: Float = 0) {
            let q = simd_quatf(angle: yawR, axis: SIMD3(0, 1, 0))
                * simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
                * simd_quatf(angle: out, axis: SIMD3(0, 0, 1))
            e.orientation = simd_slerp(e.orientation, q, ease)
        }
        hips.position.y += (hipsY - hips.position.y) * ease
        turn(hips, pitch: hipsPitch)
        turn(legL, pitch: legs.0)
        turn(legR, pitch: legs.1)
        turn(armL, pitch: arms.0, out: armsOut.0)
        turn(armR, pitch: arms.1, out: armsOut.1)
        turn(neck, pitch: neckPitch, yawR: neckYaw)
    }
}
