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

/// Owns the Metal view for a world pane. Held by the model so the scene
/// survives tab switches instead of being rebuilt on every re-render.
/// The MTKView tells the runtime when it enters or leaves a window, which the
/// run policy needs: a view SwiftUI has unmounted (workspace switch) or whose
/// window is hidden must not keep a render loop alive.
final class WorldMTKView: MTKView {
    var onWindowChange: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}

final class WorldRuntime {
    let view: WorldMTKView
    private var renderer: WorldRenderer?
    private var timer: Timer?
    private var occlusionObserver: NSObjectProtocol?
    private var demoTick = 0
    /// Cycles fake agents through every phase, so the behaviours can be seen
    /// without standing up five live agents. File > Toggle Agent World Demo.
    var demoMode = false { didSet { if oldValue != demoMode { renderer?.resetStats(); applyRunPolicy() } } }
    /// Whether the pane's tab is the visible one, pushed in by WorldHost.
    var tabActive = true { didSet { if oldValue != tabActive { applyRunPolicy() } } }
    private var hasContent = false
    weak var model: AppModel?

    func resetStats() { renderer?.resetStats() }
    var lastFrameMs: Double { renderer?.lastFrameMs ?? 0 }
    var worstFrameMs: Double { renderer?.worstFrameMs ?? 0 }
    var worstGpuMs: Double { renderer?.worstGpuMs ?? 0 }

    init(model: AppModel?) {
        self.model = model
        let device = MTLCreateSystemDefaultDevice()
        view = WorldMTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.078, green: 0.078, blue: 0.09, alpha: 1)
        // paused until the renderer exists and the policy decides to run
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        // match the display rather than assuming 60: this panel is ProMotion,
        // where a frame budget is 8.3ms, not 16.7
        view.preferredFramesPerSecond = Int((NSScreen.main?.maximumFramesPerSecond).map(Double.init) ?? 60)

        view.onWindowChange = { [weak self] in
            guard let self else { return }
            self.watchOcclusion(of: self.view.window)
            self.applyRunPolicy()
        }

        // Shader compilation takes long enough to notice; doing it inline meant
        // the first world pane stalled the SwiftUI body that created it.
        if let device {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let r = WorldRenderer(device: device)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.renderer = r
                    if let r { self.view.delegate = r } else {
                        NSLog("amux: world shader failed to build, pane will not render")
                    }
                    self.sync()
                }
            }
        } else {
            NSLog("amux: Metal unavailable, world pane will not render")
        }

        // Only the roster and phases are pushed from here; all motion is in the
        // shader, so this does not need to run anywhere near frame rate.
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit {
        timer?.invalidate()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    private func watchOcclusion(of window: NSWindow?) {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = window.map { w in
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.applyRunPolicy() } }
        }
    }

    /// One place decides whether the render loop runs. It runs only when the
    /// renderer exists, the view is in a window that is actually visible, the
    /// tab is the focused one, and there is something animated to show — an
    /// empty room is drawn once and then costs nothing.
    private func applyRunPolicy() {
        let windowVisible = view.window.map {
            $0.occlusionState.contains(.visible) && $0.isVisible
        } ?? false
        let shouldRun = renderer != nil && windowVisible && tabActive
            && (hasContent || demoMode)
        if view.isPaused == shouldRun {
            view.isPaused = !shouldRun
            if shouldRun { renderer?.resetStats() }
        }
        // a paused pane still needs its static frame (floor, resting avatars)
        if !shouldRun, renderer != nil, view.window != nil { view.draw() }
    }

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
        defer {
            hasContent = demoMode || !(model?.state?.agents ?? []).isEmpty
            applyRunPolicy()
        }
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
        runtime.tabActive = isActive
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
