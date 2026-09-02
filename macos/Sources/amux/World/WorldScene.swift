import RealityKit
import AppKit
import Metal
import simd

// MARK: - The scene
//
// Owns the room, the camera and the actors, and reconciles the roster of live
// agents against the actors in the room: a new agent walks in, a missing one
// walks out, an existing one changes what it is doing.
//
// Rendering is a RealityRenderer driven by the runtime, one frame at a time,
// into whatever texture it is handed. That is the whole reason it is not an
// ARView: an ARView renders at the display's full rate for as long as it
// exists, and the runtime could neither slow it down nor bring it back once it
// had left its window. Here nothing renders unless render(into:) is called, so
// the runtime chooses the rate, and zero is a rate.

struct WorldAgentState: Equatable {
    let paneId: String
    let label: String
    let kind: String
    let phase: AgentPhase
}

@MainActor
final class WorldScene {
    let renderer: RealityRenderer?
    let root = Entity()
    let camera = WorldCamera()
    let daylight = WorldDaylight()

    private(set) var layout = WorldLayout()
    private(set) var ready = false
    private var actors: [String: WorldActor] = [:]
    private var occupancy: [Int: String] = [:]
    private var standingUse: [Int: String] = [:]
    private var pending: [WorldAgentState]?
    private var spawning: Set<String> = []
    private var clock: Float = 0
    private var racks: [Entity] = []
    private var neon: Entity?
    private var neonMaterial: PhysicallyBasedMaterial?
    private var doorSwing: Float = 0
    private var anchored = false
    private var framesRendered = 0

    /// Smoothed frames per second, for verification rather than display.
    private(set) var fps: Double = 0
    /// Fires once the complete room has been drawn a couple of times, so the
    /// runtime can fade the pane up over the loading state.
    var onFirstFrame: (() -> Void)?

    init() {
        renderer = try? RealityRenderer()
        if renderer == nil { NSLog("amux world: RealityRenderer unavailable; the pane will stay on its loading state") }
        renderer?.cameraSettings.colorBackground = .color(CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1))
        renderer?.cameraSettings.antialiasing = .multisample4X
        root.addChild(camera.rig)
        daylight.renderer = renderer
        daylight.install(under: root)
        Task { await build() }
    }

    private func build() async {
        // `amux -worldSlowLoad <seconds>` holds the room back so the loading
        // state can be seen; the real build is under a second on a warm cache
        let slow = UserDefaults.standard.integer(forKey: "worldSlowLoad")
        if slow > 0 { try? await Task.sleep(for: .seconds(slow)) }
        layout = await WorldRoom.build(under: root, daylight: daylight)
        camera.focus = layout.focus
        racks = root.children.filter { $0.name.hasPrefix("rack") }
        if let n = root.findEntity(named: "neon"),
           let me = n.children.first?.children.first as? ModelEntity,
           let m = me.model?.materials.first as? PhysicallyBasedMaterial {
            neon = me
            neonMaterial = m
        }
        // the room goes in whole, once built, never piece by piece
        renderer?.entities.append(root)
        renderer?.activeCamera = camera.cameraEntity
        anchored = true
        ready = true
        if let p = pending { pending = nil; apply(roster: p) }
    }

    // MARK: rendering

    /// Advances the world by `dt` and draws it into `texture`. `onComplete`
    /// runs when the GPU has finished, off the main thread; present there.
    /// Does nothing until the room is built.
    func render(into texture: MTLTexture, dt: Float, hour: Float, onComplete: @escaping @Sendable () -> Void) -> Bool {
        guard anchored, let renderer else { return false }
        daylight.apply(hour: hour)
        tick(dt: dt)
        do {
            let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
            try renderer.updateAndRender(deltaTime: Double(dt), cameraOutput: output, onComplete: { _ in onComplete() })
        } catch {
            NSLog("amux world: render failed: \(error)")
            return false
        }
        framesRendered += 1
        if framesRendered == 3 { onFirstFrame?() }
        return true
    }

    func viewResized(to size: CGSize) { camera.viewResized(to: size) }

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
                spawn(a)
            }
        }
        for (id, actor) in actors where !live.contains(id) {
            actor.leave(via: layout.threshold, to: layout.spawn)
        }
    }

    private func spawn(_ a: WorldAgentState) {
        spawning.remove(a.paneId)
        let actor = WorldActor(paneId: a.paneId, label: a.label, kind: a.kind)
        actor.onDoor = { [weak self] in self?.doorSwing = 1 }
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
        m.emissiveColor = .init(color: color ?? WorldRoom.screenGreen)
        m.emissiveIntensity = color == nil ? 1.6 : 1.3
        screen.model?.materials = [m]
    }

    func notifyMessage(_ paneId: String) {
        actors[paneId]?.react(.message)
    }

    // MARK: per frame

    private func tick(dt: Float) {
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
    }

    /// The little life the room has on its own: rack LEDs blinking, the neon
    /// sign buzzing, the door swinging wide when someone passes and drifting
    /// back to ajar. Cheap, and it is what makes an empty den not look paused.
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
            m.emissiveIntensity = max(0.15, flicker * daylight.neonLevel)
            (neon as? ModelEntity)?.model?.materials = [m]
        }
        if let door = layout.door {
            doorSwing = max(0, doorSwing - dt * 0.35)
            let ajar: Float = 1.7, wide: Float = 2.6
            let target = ajar + (wide - ajar) * sin(min(1, doorSwing) * .pi)
            let q = simd_quatf(angle: target, axis: SIMD3(0, 1, 0))
            door.orientation = simd_slerp(door.orientation, q, min(1, dt * 6))
        }
    }
}
