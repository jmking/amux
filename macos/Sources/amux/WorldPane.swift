import SwiftUI
import SceneKit
import AppKit

// MARK: - The agent world
//
// A pane that shows every live agent as an avatar in a shared room and animates
// it from what that agent is actually doing. Coarse pane state drives the
// fallback behaviour, and the normalised event stream (AgentSources) sharpens it
// into thinking / tool / network when the agent is one we can read.
//
// Prototype: not on the release path.

private let deskSpacing: CGFloat = 2.6
private let perRow = 4

/// One agent's avatar and the behaviour currently playing on it.
final class AgentAvatar {
    let paneId: String
    let root = SCNNode()
    private let body = SCNNode()
    private let head = SCNNode()
    private let orb = SCNNode()          // thought bubble / packet
    private let marker = SCNNode()       // "needs you" flag
    private var currentBehaviour: String = ""
    private let tint: NSColor

    init(paneId: String, kind: String, label: String, slot: Int, of total: Int) {
        self.paneId = paneId
        tint = NSColor(hex: AgentBrand.of(kind).color)

        let bodyGeo = SCNCapsule(capRadius: 0.28, height: 1.0)
        bodyGeo.firstMaterial?.diffuse.contents = tint
        bodyGeo.firstMaterial?.roughness.contents = 0.85
        body.geometry = bodyGeo
        body.position = SCNVector3(0, 0.5, 0)

        let headGeo = SCNSphere(radius: 0.24)
        headGeo.firstMaterial?.diffuse.contents = tint.blended(withFraction: 0.35, of: .white) ?? tint
        head.geometry = headGeo
        head.position = SCNVector3(0, 1.15, 0)

        let orbGeo = SCNSphere(radius: 0.1)
        orbGeo.firstMaterial?.emission.contents = NSColor.white
        orbGeo.firstMaterial?.diffuse.contents = NSColor.white
        orb.geometry = orbGeo
        orb.position = SCNVector3(0, 1.7, 0)
        orb.isHidden = true

        let markGeo = SCNBox(width: 0.09, height: 0.42, length: 0.09, chamferRadius: 0.02)
        markGeo.firstMaterial?.emission.contents = NSColor.systemRed
        markGeo.firstMaterial?.diffuse.contents = NSColor.systemRed
        marker.geometry = markGeo
        marker.position = SCNVector3(0, 1.85, 0)
        marker.isHidden = true

        root.addChildNode(body)
        root.addChildNode(head)
        root.addChildNode(orb)
        root.addChildNode(marker)
        root.addChildNode(Self.nameplate(label))
        reslot(slot, of: total, animated: false)

        // arriving agents scale up rather than popping into existence
        root.scale = SCNVector3Zero
        root.runAction(.sequence([
            .scale(to: 1.12, duration: 0.22),
            .scale(to: 1.0, duration: 0.10)]))
    }

    /// Shrinks away and takes its node with it, so a departing agent reads as
    /// leaving rather than blinking out.
    func retire() {
        root.removeAllActions()
        root.runAction(.sequence([
            .scale(to: 0, duration: 0.28),
            .removeFromParentNode()]))
    }

    private static func nameplate(_ text: String) -> SCNNode {
        let t = SCNText(string: text, extrusionDepth: 0.01)
        t.font = NSFont.systemFont(ofSize: 1, weight: .medium)
        t.flatness = 0.05
        t.firstMaterial?.diffuse.contents = NSColor.white
        let n = SCNNode(geometry: t)
        n.scale = SCNVector3(0.13, 0.13, 0.13)
        let (minb, maxb) = t.boundingBox
        n.pivot = SCNMatrix4MakeTranslation((minb.x + maxb.x) / 2, 0, 0)
        n.position = SCNVector3(0, 1.95, 0)
        n.constraints = [SCNBillboardConstraint()]
        return n
    }

    /// Swaps the looping animation when the agent changes what it is doing.
    /// Behaviours are keyed so re-applying the same one does not restart it.
    func apply(phase: AgentPhase, detail: String) {
        let key = phase.rawValue
        guard key != currentBehaviour else { return }
        currentBehaviour = key

        body.removeAllActions()
        head.removeAllActions()
        orb.removeAllActions()
        marker.removeAllActions()
        orb.isHidden = true
        marker.isHidden = true
        body.position = SCNVector3(0, 0.5, 0)
        head.eulerAngles = SCNVector3Zero

        switch phase {
        case .thinking:
            // slow float, with a thought orb pulsing overhead
            body.runAction(.repeatForever(.sequence([
                .moveBy(x: 0, y: 0.06, z: 0, duration: 1.4),
                .moveBy(x: 0, y: -0.06, z: 0, duration: 1.4)])))
            head.runAction(.repeatForever(.sequence([
                .rotateBy(x: 0, y: 0, z: 0.12, duration: 1.6),
                .rotateBy(x: 0, y: 0, z: -0.12, duration: 1.6)])))
            orb.isHidden = false
            orb.runAction(.repeatForever(.sequence([
                .scale(to: 1.5, duration: 0.9), .scale(to: 0.8, duration: 0.9)])))

        case .tool:
            // heads-down typing: quick, small, busy
            body.runAction(.repeatForever(.sequence([
                .moveBy(x: 0, y: -0.05, z: 0, duration: 0.16),
                .moveBy(x: 0, y: 0.05, z: 0, duration: 0.16)])))
            head.runAction(.rotateTo(x: 0.35, y: 0, z: 0, duration: 0.3))

        case .network:
            // a packet leaves the agent, flies out and comes back
            orb.isHidden = false
            orb.geometry?.firstMaterial?.emission.contents = NSColor.systemTeal
            orb.runAction(.repeatForever(.sequence([
                .move(to: SCNVector3(0, 1.7, 0), duration: 0),
                .move(to: SCNVector3(0, 3.2, -3.0), duration: 0.5),
                .move(to: SCNVector3(0, 1.7, 0), duration: 0.5)])))
            body.runAction(.repeatForever(.sequence([
                .moveBy(x: 0, y: 0.03, z: 0, duration: 0.5),
                .moveBy(x: 0, y: -0.03, z: 0, duration: 0.5)])))

        case .waiting:
            // stands up and waves a flag: this is the one that wants you
            marker.isHidden = false
            marker.runAction(.repeatForever(.sequence([
                .rotateBy(x: 0, y: 0, z: 0.5, duration: 0.35),
                .rotateBy(x: 0, y: 0, z: -0.5, duration: 0.35)])))
            body.runAction(.repeatForever(.sequence([
                .moveBy(x: 0, y: 0.16, z: 0, duration: 0.32),
                .moveBy(x: 0, y: -0.16, z: 0, duration: 0.32)])))

        case .done:
            // one celebratory hop and spin, then clear the key so the next sync
            // re-evaluates and the avatar settles into whatever comes next
            body.runAction(.sequence([
                .moveBy(x: 0, y: 0.5, z: 0, duration: 0.22),
                .moveBy(x: 0, y: -0.5, z: 0, duration: 0.22)]))
            root.runAction(.sequence([
                .rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 0.6),
                .run { [weak self] _ in self?.currentBehaviour = "" }]))

        case .idle:
            body.runAction(.repeatForever(.sequence([
                .rotateBy(x: 0, y: 0.18, z: 0, duration: 2.2),
                .rotateBy(x: 0, y: -0.18, z: 0, duration: 2.2)])))
        }
    }

    func reslot(_ slot: Int, of total: Int, animated: Bool = true) {
        let rows = max(1, Int(ceil(Double(total) / Double(perRow))))
        let row = slot / perRow
        // the last row is usually short; centre it on its own width
        let inRow = min(perRow, total - row * perRow)
        let col = slot % perRow
        let target = SCNVector3(
            (CGFloat(col) - CGFloat(inRow - 1) / 2) * deskSpacing,
            0,
            (CGFloat(row) - CGFloat(rows - 1) / 2) * deskSpacing)
        guard animated else { root.position = target; return }
        // the grid reflows when anyone joins or leaves: glide, do not teleport
        let dx = abs(root.position.x - target.x), dz = abs(root.position.z - target.z)
        guard dx > 0.001 || dz > 0.001 else { return }
        root.runAction(.move(to: target, duration: 0.45))
    }
}

/// Owns the SceneKit view for a world pane. Held by the model so the scene
/// survives tab switches instead of being rebuilt on every re-render.
final class WorldRuntime {
    let view = SCNView()
    private let scene = SCNScene()
    private let agentRoot = SCNNode()
    private var avatars: [String: AgentAvatar] = [:]
    private var timer: Timer?
    private var demoTick = 0
    private var lastChange = Date.distantPast
    /// Prototype affordance: fake agents cycling every phase, so the behaviours
    /// can be reviewed without five live agents.
    var demoMode = false { didSet { if oldValue != demoMode { resetAvatars() } } }
    weak var model: AppModel?

    init(model: AppModel?) {
        self.model = model
        buildRoom()
        view.scene = scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = NSColor(hex: 0x141417)
        view.rendersContinuously = false

        // The scene animates itself once a behaviour is set, so this only has to
        // notice when an agent changes what it is doing.
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    private func buildRoom() {
        let floorGeo = SCNFloor()
        floorGeo.reflectivity = 0.025
        floorGeo.firstMaterial?.diffuse.contents = NSColor(hex: 0x232327)
        scene.rootNode.addChildNode(SCNNode(geometry: floorGeo))

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 700
        key.light?.castsShadow = true
        key.light?.shadowMode = .deferred
        key.light?.shadowRadius = 8
        key.light?.shadowColor = NSColor.black.withAlphaComponent(0.35)
        key.eulerAngles = SCNVector3(-CGFloat.pi / 3, CGFloat.pi / 5, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 320
        fill.light?.color = NSColor(hex: 0x8a8aa0)
        scene.rootNode.addChildNode(fill)

        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 42
        // fieldOfView applies to the larger axis by default, so a world pane
        // split narrow would crop the outer avatars. Pin it horizontally: the
        // grid is wider than it is deep, so fitting the width fits the room.
        cam.camera?.projectionDirection = .horizontal
        cam.camera?.wantsHDR = true
        cam.position = SCNVector3(0, 6.5, 12.5)
        cam.eulerAngles = SCNVector3(-0.42, 0, 0)
        scene.rootNode.addChildNode(cam)
        view.pointOfView = cam

        scene.rootNode.addChildNode(agentRoot)
    }

    /// Reconciles the avatars against the live agent list, then pushes each one
    /// the phase it should be playing.
    private func resetAvatars() {
        // retire() rather than a bare remove, so leaving demo mode exercises the
        // same departure the real agent path uses
        for (_, a) in avatars { a.retire() }
        avatars.removeAll()
        demoTick = 0
        lastChange = Date()
    }

    private static let demoCast: [(String, String)] = [
        ("claude", "reviewer"), ("codex", "migrator"),
        ("rovo", "triage"), ("claude", "docs"), ("codex", "tests"),
    ]
    private static let demoPhases: [AgentPhase] = [
        .thinking, .tool, .network, .waiting, .done, .idle,
    ]

    @MainActor private func syncDemo() {
        demoTick += 1
        for (i, cast) in Self.demoCast.enumerated() {
            let paneId = "demo:\(i)"
            let avatar: AgentAvatar
            if let existing = avatars[paneId] { avatar = existing }
            else {
                avatar = AgentAvatar(paneId: paneId, kind: cast.0, label: cast.1,
                                     slot: i, of: Self.demoCast.count)
                avatars[paneId] = avatar
                agentRoot.addChildNode(avatar.root)
            }
            // stagger the cast so every behaviour is on screen at once
            let phase = Self.demoPhases[((demoTick / 8) + i) % Self.demoPhases.count]
            avatar.apply(phase: phase, detail: "demo")
        }
        view.rendersContinuously = true
    }

    @MainActor func sync() {
        if demoMode { syncDemo(); return }
        guard let model else { return }
        let agents = model.state?.agents ?? []
        let live = Set(agents.map(\.paneId))

        for (paneId, avatar) in avatars where !live.contains(paneId) {
            avatar.retire()
            avatars.removeValue(forKey: paneId)
            lastChange = Date()
        }

        for (slot, a) in agents.enumerated() {
            let avatar: AgentAvatar
            if let existing = avatars[a.paneId] {
                avatar = existing
                avatar.reslot(slot, of: agents.count)
            } else {
                avatar = AgentAvatar(paneId: a.paneId, kind: a.kind,
                                     label: a.name ?? a.tab, slot: slot, of: agents.count)
                avatars[a.paneId] = avatar
                agentRoot.addChildNode(avatar.root)
                lastChange = Date()
            }
            // an event is a sharper signal than the coarse state, when we have one
            if let e = model.eventLog.latestPhase(paneId: a.paneId, within: 8) {
                avatar.apply(phase: e.phase, detail: e.detail)
            } else {
                avatar.apply(phase: AgentPhase.fromState(a.state), detail: a.state)
            }
        }
        view.rendersContinuously = !avatars.isEmpty
    }
}

struct WorldHost: NSViewRepresentable {
    let runtime: WorldRuntime

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if runtime.view.superview !== nsView { attach(to: nsView) }
    }

    private func attach(to container: NSView) {
        let v = runtime.view
        v.removeFromSuperview()
        v.frame = container.bounds
        v.autoresizingMask = [.width, .height]
        container.addSubview(v)
    }
}

/// Thin header so a world pane reads like the other pane kinds.
struct WorldToolbar: View {
    @ObservedObject var model: AppModel
    let paneId: String
    @Environment(\.palette) private var pal
    @State private var demoOn = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(pal.faint2)
                .frame(width: 16, height: 24)
                .contentShape(Rectangle())
                .onDrag {
                    model.beginDrag("pane:\(paneId)")
                    return PaneDrag.provider("pane:\(paneId)")
                }
                .help("Drag to move this pane")
            Image(systemName: "cube.transparent").font(.system(size: 11))
            Text("agent world").font(.system(size: 13)).foregroundStyle(pal.ink)
            Spacer(minLength: 4)
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(pal.faint2)
            Button {
                let rt = model.worldRuntime(for: paneId)
                rt.demoMode.toggle()
                demoOn = rt.demoMode
            } label: {
                Text("demo")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(demoOn ? pal.spot.opacity(0.8) : pal.mass.opacity(0.7)))
                    .foregroundStyle(demoOn ? pal.spotInk : pal.faint)
            }
            .buttonStyle(.plain)
            .help("Cycle fake agents through every behaviour")
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(pal.panel)
        .contentShape(Rectangle())
        .onDrag {
            model.beginDrag("pane:\(paneId)")
            return PaneDrag.provider("pane:\(paneId)")
        }
        .contextMenu {
            Button("Split right") { model.splitPane(paneId, direction: "right") }
            Button("Split down") { model.splitPane(paneId, direction: "down") }
            Button("Zoom") { model.zoomPane(paneId) }
            Divider()
            Button("Close pane", role: .destructive) { model.requestClosePane(paneId) }
        }
        .help("Drag to move this pane · drop on another pane's edge to snap")
    }

    private var summary: String {
        let agents = model.state?.agents ?? []
        if agents.isEmpty { return "no live agents" }
        var counts: [String: Int] = [:]
        for a in agents {
            let p = model.eventLog.latestPhase(paneId: a.paneId, within: 8)?.phase
                ?? AgentPhase.fromState(a.state)
            counts[p.rawValue, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }
            .joined(separator: " · ")
    }
}
