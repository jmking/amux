import RealityKit
import AppKit
import Combine
import simd

// MARK: - The scene
//
// Owns the room, the camera and the actors, and reconciles the roster of live
// agents against the actors in the room: a new agent walks in, a missing one
// walks out, an existing one changes what it is doing. Everything time-based
// runs off the render loop's update event so it stays in step with the frame.

struct WorldAgentState: Equatable {
    let paneId: String
    let label: String
    let kind: String
    let phase: AgentPhase
}

@MainActor
final class WorldScene {
    let view: ARView
    let root = AnchorEntity(world: .zero)
    let camera = WorldCamera()

    private(set) var layout = WorldLayout()
    private(set) var ready = false
    private var actors: [String: WorldActor] = [:]
    private var occupancy: [Int: String] = [:]
    private var standingUse: [Int: String] = [:]
    private var pending: [WorldAgentState]?
    private var spawning: Set<String> = []
    private var updateSub: (any Cancellable)?
    private var clock: Float = 0
    private var racks: [Entity] = []
    private var neon: Entity?
    private var neonMaterial: PhysicallyBasedMaterial?

    /// Smoothed frames per second, for verification rather than display.
    private(set) var fps: Double = 0
    /// RealityKit keeps ticking a view that is not in a window; the runtime
    /// clears this when the pane is hidden so the tick costs nothing.
    var active = true

    init(view: ARView) {
        self.view = view
        view.scene.addAnchor(root)
        root.addChild(camera.rig)
        updateSub = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] e in
            MainActor.assumeIsolated { self?.tick(dt: Float(e.deltaTime)) }
        }
        // `amux -worldStats 1` overlays RealityKit's frame and mesh statistics
        if UserDefaults.standard.bool(forKey: "worldStats") { view.debugOptions = [.showStatistics] }
        Task { await build() }
    }

    private func build() async {
        if let env = await WorldRoom.environment() {
            view.environment.lighting.resource = env
            view.environment.lighting.intensityExponent = 2.0
            view.environment.background = .skybox(env)
        }
        layout = await WorldRoom.build(under: root)
        camera.focus = layout.focus
        racks = root.children.filter { $0.name.hasPrefix("rack") }
        if let n = root.findEntity(named: "neon"),
           let me = n.children.first?.children.first as? ModelEntity,
           let m = me.model?.materials.first as? PhysicallyBasedMaterial {
            neon = me
            neonMaterial = m
        }
        ready = true
        if let p = pending { pending = nil; apply(roster: p) }
    }

    // MARK: roster

    func apply(roster: [WorldAgentState]) {
        guard ready else { pending = roster; return }
        let live = Set(roster.map(\.paneId))

        for a in roster {
            if let actor = actors[a.paneId] {
                actor.setPhase(a.phase)
                actor.setLabel(a.label)
            } else if !spawning.contains(a.paneId) {
                spawning.insert(a.paneId)
                Task { await spawn(a) }
            }
        }
        for (id, actor) in actors where !live.contains(id) {
            actor.leave(via: layout.threshold, to: layout.spawn)
        }
    }

    private func spawn(_ a: WorldAgentState) async {
        let model = await WorldAssets.shared.instance("character")
        let clips = model == nil ? [:] : await WorldAssets.shared.characterClips()
        spawning.remove(a.paneId)
        let actor = WorldActor(paneId: a.paneId, label: a.label, kind: a.kind, model: model, clips: clips)
        actor.onDoor = { [weak self] in self?.swingDoor() }
        actor.setPhase(a.phase)
        root.addChild(actor.entity)
        actors[a.paneId] = actor
        if let (i, seat) = claimSeat(for: a.paneId) {
            tintScreen(seat, to: actor.color)
            actor.enter(from: layout.spawn, via: layout.threshold, to: seat, index: i)
        } else {
            let i = (0..<layout.standing.count).first { standingUse[$0] == nil } ?? 0
            standingUse[i] = a.paneId
            actor.stand(at: layout.standing[i], from: layout.spawn, via: layout.threshold)
        }
    }

    private func claimSeat(for paneId: String) -> (Int, WorldSeat)? {
        for (i, s) in layout.seats.enumerated() where occupancy[i] == nil {
            occupancy[i] = paneId
            return (i, s)
        }
        return nil
    }

    private func tintScreen(_ seat: WorldSeat, to color: NSColor?) {
        guard let screen = seat.screen else { return }
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: .black)
        m.emissiveColor = .init(color: color ?? NSColor(red: 0.3, green: 0.9, blue: 0.7, alpha: 1))
        m.emissiveIntensity = color == nil ? 1.6 : 1.3
        screen.model?.materials = [m]
    }

    /// The door swings wide when someone passes and drifts back to ajar.
    private var doorSwing: Float = 0
    private func swingDoor() { doorSwing = 1 }

    func notifyMessage(_ paneId: String) {
        actors[paneId]?.react(.message)
    }

    // MARK: per frame

    private func tick(dt: Float) {
        guard active else { return }
        let dt = min(dt, 0.1)
        clock += dt
        if dt > 0 { fps = fps == 0 ? Double(1 / dt) : fps * 0.95 + Double(1 / dt) * 0.05 }
        camera.tick(dt: dt)
        let forward = camera.forward
        for (id, actor) in actors {
            actor.tick(dt: dt, cameraForward: forward)
            if actor.isGone {
                if let i = actor.seatIndex {
                    occupancy[i] = nil
                    tintScreen(layout.seats[i], to: nil)
                }
                for (k, v) in standingUse where v == id { standingUse[k] = nil }
                actor.entity.removeFromParent()
                actors[id] = nil
            }
        }
        dress(dt: dt)
        if let door = layout.door {
            doorSwing = max(0, doorSwing - dt * 0.35)
            let ajar: Float = -1.7, wide: Float = -2.6
            let target = ajar + (wide - ajar) * sin(min(1, doorSwing) * .pi)
            let q = simd_quatf(angle: target, axis: SIMD3(0, 1, 0))
            door.orientation = simd_slerp(door.orientation, q, min(1, dt * 6))
        }
    }

    /// The little life the room has on its own: rack LEDs blinking, the neon
    /// sign buzzing. Cheap, and it is what makes an empty den not look paused.
    private func dress(dt: Float) {
        if Int(clock * 10) != Int((clock - dt) * 10) {
            for (r, rack) in racks.enumerated() {
                for i in 0..<9 {
                    guard let led = rack.findEntity(named: "led\(i)") else { continue }
                    let h = (i * 7 + r * 13 + Int(clock * 10)) % 11
                    led.isEnabled = h != 0 && h != 5
                }
            }
        }
        if let neon, var m = neonMaterial {
            let flicker: Float = clock.truncatingRemainder(dividingBy: 7) > 6.7 ? (sin(clock * 90) > 0.2 ? 5 : 1.2) : 5
            m.emissiveIntensity = flicker
            (neon as? ModelEntity)?.model?.materials = [m]
        }
    }
}
