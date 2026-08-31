import SwiftUI
import MetalKit
import simd
import AppKit

// MARK: - The agent world
//
// A pane that shows every live agent as an avatar in a shared room and animates
// it from what that agent is actually doing. Coarse pane state drives the
// fallback behaviour, and the normalised event stream (AgentSources) sharpens it
// into thinking / tool / network when the agent is one we can read.
//
// Prototype: not on the release path.

/// Owns the Metal view for a world pane. Held by the model so the scene
/// survives tab switches instead of being rebuilt on every re-render.
final class WorldRuntime {
    let view: MTKView
    private let renderer: WorldRenderer?
    private var timer: Timer?
    private var demoTick = 0
    /// Prototype affordance: fake agents cycling every phase, so the behaviours
    /// can be reviewed without five live agents.
    var demoMode = false { didSet { if oldValue != demoMode { renderer?.resetStats() } } }
    weak var model: AppModel?

    func resetStats() { renderer?.resetStats() }
    var lastFrameMs: Double { renderer?.lastFrameMs ?? 0 }
    var worstFrameMs: Double { renderer?.worstFrameMs ?? 0 }
    var worstGpuMs: Double { renderer?.worstGpuMs ?? 0 }

    init(model: AppModel?) {
        self.model = model
        let device = MTLCreateSystemDefaultDevice()
        view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.078, green: 0.078, blue: 0.09, alpha: 1)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        // match the display rather than assuming 60: this panel is ProMotion,
        // where a frame budget is 8.3ms, not 16.7
        view.preferredFramesPerSecond = Int((NSScreen.main?.maximumFramesPerSecond).map(Double.init) ?? 60)

        renderer = device.flatMap { WorldRenderer(device: $0) }
        if let renderer {
            view.delegate = renderer
        } else {
            NSLog("amux: Metal unavailable, world pane will not render")
            view.isPaused = true
        }

        // Only the roster and phases are pushed from here; all motion is in the
        // shader, so this does not need to run anywhere near frame rate.
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    private static let demoCast: [(String, String)] = [
        ("claude", "reviewer"), ("codex", "migrator"),
        ("rovo", "triage"), ("claude", "docs"), ("codex", "tests"),
    ]
    private static let demoPhases: [AgentPhase] = [
        .thinking, .tool, .network, .waiting, .done, .idle,
    ]

    private func brandColor(_ kind: String) -> SIMD4<Float> {
        let hex = AgentBrand.of(kind).color
        return SIMD4(Float((hex >> 16) & 0xff) / 255,
                     Float((hex >> 8) & 0xff) / 255,
                     Float(hex & 0xff) / 255, 1)
    }

    @MainActor func sync() {
        guard let renderer else { return }
        if demoMode {
            demoTick += 1
            let cast = Self.demoCast
            renderer.update(agents: cast.enumerated().map { i, c in
                WorldAgentState(
                    paneId: "demo:\(i)", label: c.1, color: brandColor(c.0),
                    phase: Self.demoPhases[((demoTick / 12) + i) % Self.demoPhases.count],
                    slot: i, total: cast.count)
            })
            return
        }
        guard let model else { return }
        let agents = model.state?.agents ?? []
        renderer.update(agents: agents.enumerated().map { slot, a in
            // an event is a sharper signal than the coarse state, when we have one
            let phase = model.eventLog.latestPhase(paneId: a.paneId, within: 8)?.phase
                ?? AgentPhase.fromState(a.state)
            return WorldAgentState(
                paneId: a.paneId, label: a.name ?? a.tab, color: brandColor(a.kind),
                phase: phase, slot: slot, total: agents.count)
        })
    }
}

struct WorldHost: NSViewRepresentable {
    let runtime: WorldRuntime
    /// Background tabs stay mounted, so without this every world pane ever
    /// opened would keep rendering at the display's full rate.
    var isActive: Bool = true

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if runtime.view.superview !== nsView { attach(to: nsView) }
        if runtime.view.isPaused == isActive {
            runtime.view.isPaused = !isActive
            if isActive { runtime.resetStats() }
        }
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
                } preview: {
                    DragChip(icon: "cube.transparent", label: "agent world")
                        .environment(\.palette, pal)
                }
                .help("Drag to move this pane")
            Image(systemName: "cube.transparent").font(.system(size: 11))
            Text("agent world").font(.system(size: 13)).foregroundStyle(pal.ink)
            Spacer(minLength: 4)
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(pal.faint2)
            // shown so the frame budget can be checked rather than claimed.
            // Needs its own clock: nothing in the model changes per frame.
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(frameStat)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(frameOK ? pal.faint2 : AgentStateColor.color("blocked"))
            }
            .help("Last frame and worst frame over the recent window")
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
            Divider().frame(height: 14).overlay(pal.line2)
            PaneChromeButtons(model: model, paneId: paneId)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(pal.panel)
        .contentShape(Rectangle())
        .onDrag {
            model.beginDrag("pane:\(paneId)")
            return PaneDrag.provider("pane:\(paneId)")
        } preview: {
            DragChip(icon: "cube.transparent", label: "agent world")
                .environment(\.palette, pal)
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

    /// Worst frame in the recent window, which is the number that matters: an
    /// average can look fine while every tenth frame is dropped.
    private var frameOK: Bool {
        let worst = model.worldRuntime(for: paneId).worstGpuMs
        return worst == 0 || worst < 8.3     // a 120Hz budget, not a 60Hz one
    }

    private var frameStat: String {
        let rt = model.worldRuntime(for: paneId)
        guard rt.lastFrameMs > 0 else { return "" }
        let fps = rt.lastFrameMs > 0 ? 1000 / rt.lastFrameMs : 0
        return String(format: "%.0f fps · gpu worst %.2fms", fps, rt.worstGpuMs)
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
