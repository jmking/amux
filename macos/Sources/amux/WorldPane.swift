import SwiftUI
import RealityKit
import AppKit

// MARK: - The agent world
//
// A pane that shows every live agent as a hooded figure in a shared den and
// animates it from what that agent is actually doing. Coarse pane state drives
// the fallback behaviour, and the normalised event stream (AgentSources)
// sharpens it into thinking / tool / network when the agent is one we can read.
//
// Rendering is RealityKit. The scene lives in WorldScene; this file is the
// runtime around it: the view, when it is allowed to render, and the bridge
// from the app model's roster to the scene.

/// The RealityKit view. Reports window changes for the run policy and turns
/// drags and scrolls into camera moves.
final class WorldARView: ARView {
    var onWindowChange: (() -> Void)?
    var onOrbit: ((Float) -> Void)?
    var onZoom: ((Float) -> Void)?
    var onResize: ((CGSize) -> Void)?

    override func layout() {
        super.layout()
        onResize?(bounds.size)
    }

    @MainActor required dynamic init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @MainActor required dynamic init?(coder decoder: NSCoder) {
        super.init(coder: decoder)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDragged(with event: NSEvent) {
        onOrbit?(Float(event.deltaX))
    }

    override func scrollWheel(with event: NSEvent) {
        onZoom?(Float(event.scrollingDeltaY))
    }
}

@MainActor
final class WorldRuntime: ObservableObject {
    let scene: WorldScene
    /// True once the room has been built and drawn; the pane shows a loading
    /// state until then rather than pieces popping in.
    @Published private(set) var isReady = false
    /// Exists only while the pane is on screen. RealityKit renders a view at
    /// the display's full rate for as long as it exists, on screen or not, and
    /// a view that has once left its window never renders again; so the view
    /// is made when the pane is shown and thrown away when it is hidden. The
    /// scene, with the room and the crew, persists in between.
    private(set) var view: WorldARView?
    private weak var container: NSView?
    private var teardown: Task<Void, Never>?
    private var lastDiscard: CFAbsoluteTime = 0
    private var rebuildPending = false
    private var timer: Timer?
    private var occlusionObserver: NSObjectProtocol?
    private var demoTick = 0
    private var demoAway: Int?
    /// Cycles fake agents through every phase, so the behaviours can be seen
    /// without standing up five live agents. File > Toggle Agent World Demo.
    var demoMode = false { didSet { if oldValue != demoMode { demoTick = 0; sync() } } }
    /// Whether the pane's tab is the visible one, pushed in by WorldHost.
    var tabActive = true { didSet { if oldValue != tabActive { applyRunPolicy() } } }
    weak var model: AppModel?

    var fps: Double { scene.fps }

    init(model: AppModel?) {
        self.model = model
        scene = WorldScene()
        scene.onFirstFrame = { [weak self] in self?.revealView() }
        // `amux -worldDemo 1` starts every world pane in demo mode, for testing
        demoMode = UserDefaults.standard.bool(forKey: "worldDemo")

        // Only the roster and phases are pushed from here; all motion runs off
        // the render loop, so this does not need to run anywhere near frame rate.
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

    /// The host gives the runtime its container; the run policy decides whether
    /// there is a view in it.
    func attach(to container: NSView) {
        if container !== self.container {
            // When a pane moves, SwiftUI builds the new host and dismantles the
            // old one, and the old container reports leaving its window last
            // of all. Taking that as the current container hid the fresh view
            // and tore it down: a container with no window that is not ours
            // is a host on its way out.
            guard container.window != nil || self.container == nil else { return }
            self.container = container
        }
        watchOcclusion(of: container.window)
        applyRunPolicy()
    }

    private func watchOcclusion(of window: NSWindow?) {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = window.map { w in
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.applyRunPolicy() } }
        }
    }

    private func makeView() -> WorldARView {
        let v = WorldARView(frame: .zero)
        v.environment.background = .color(NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1))
        // invisible until the room has drawn; revealView fades it up
        v.alphaValue = 0
        v.onWindowChange = { [weak self, weak v] in
            guard let self, let v else { return }
            if v.window == nil {
                // The pane was moved (or its window closed). A RealityKit view
                // that has left its window never renders again, so this one is
                // finished; the run policy makes a fresh one if the pane is
                // still on screen.
                if self.view === v { self.discardView() }
            } else {
                self.watchOcclusion(of: v.window)
            }
        }
        v.onOrbit = { [weak self] dx in self?.scene.camera.orbit(byPixels: dx) }
        v.onZoom = { [weak self] dy in self?.scene.camera.zoom(byScrollDelta: dy) }
        v.onResize = { [weak self] size in self?.scene.camera.viewResized(to: size) }
        return v
    }

    /// One place decides whether the scene renders: the pane's tab is the
    /// visible one, in a window that is actually on screen.
    private func applyRunPolicy() {
        guard let container else { return }
        let windowVisible = container.window.map {
            $0.occlusionState.contains(.visible) && $0.isVisible
        } ?? false
        let shouldRun = windowVisible && tabActive
        if shouldRun {
            teardown?.cancel()
            teardown = nil
            // a view that is not in this container has been through a move
            if let v = view, v.superview !== container { discardView() ; _ = v }
            // A view created in the same turn as another was destroyed never
            // renders (RealityKit tears its renderer down asynchronously); the
            // fresh one waits a beat.
            if view == nil, CFAbsoluteTimeGetCurrent() - lastDiscard < 0.25 {
                guard !rebuildPending else { return }
                rebuildPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.rebuildPending = false
                    self?.applyRunPolicy()
                }
                return
            }
            let v = view ?? makeView()
            view = v
            if v.superview !== container {
                v.frame = container.bounds
                v.autoresizingMask = [.width, .height]
                container.addSubview(v)
            }
            v.isHidden = false
            scene.attach(to: v)
        } else if let v = view {
            v.isHidden = true
            // a quick flip between tabs should not pay to rebuild the view
            guard teardown == nil else { return }
            teardown = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, !Task.isCancelled else { return }
                self.discardView()
                self.teardown = nil
            }
        }
    }

    private func discardView() {
        // clear first: removing the view fires its window-change callback,
        // which must not find it current and discard it again
        let v = view
        view = nil
        lastDiscard = CFAbsoluteTimeGetCurrent()
        scene.detach()
        v?.removeFromSuperview()
    }

    /// The room has drawn: fade the view up and drop the loading state.
    private func revealView() {
        guard let v = view else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            v.animator().alphaValue = 1
        }
        if !isReady { isReady = true }
    }

    private static let demoCast: [(String, String)] = [
        ("claude", "reviewer"), ("codex", "migrator"),
        ("rovo", "triage"), ("claude", "docs"), ("codex", "tests"),
    ]
    private static let demoPhases: [AgentPhase] = [
        .tool, .thinking, .network, .waiting, .done, .idle,
    ]

    func sync() {
        if demoMode {
            demoTick += 1
            let cast = Self.demoCast
            // every so often one of them leaves and comes back, to exercise the door
            if demoTick % 90 == 0 { demoAway = (demoAway.map { $0 + 1 } ?? 0) % cast.count }
            if demoTick % 90 == 45 { demoAway = nil }
            // now and then the user "sends" something to one of the crew
            if demoTick % 48 == 24 {
                let who = (demoTick / 48) % cast.count
                if who != demoAway { scene.notifyMessage("demo:\(who)") }
            }
            let roster = cast.enumerated().compactMap { i, c -> WorldAgentState? in
                if demoAway == i { return nil }
                return WorldAgentState(
                    paneId: "demo:\(i)", label: c.1, kind: c.0,
                    phase: Self.demoPhases[((demoTick / 16) + i) % Self.demoPhases.count])
            }
            scene.apply(roster: roster)
            return
        }
        guard let model else { return }
        let agents = model.state?.agents ?? []
        scene.apply(roster: agents.map { a in
            // an event is a sharper signal than the coarse state, when we have one
            let phase = model.eventLog.latestPhase(paneId: a.paneId, within: 8)?.phase
                ?? AgentPhase.fromState(a.state)
            return WorldAgentState(paneId: a.paneId, label: a.name ?? a.tab, kind: a.kind, phase: phase)
        })
    }

    /// The user just sent something to this agent's terminal.
    func noteUserInput(_ paneId: String) {
        scene.notifyMessage(paneId)
    }
}

/// The view SwiftUI owns. It is created before it is in a window, and the run
/// policy needs to know when that changes, so it reports it.
final class WorldContainerView: NSView {
    var onWindowChange: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}

struct WorldHost: NSViewRepresentable {
    let runtime: WorldRuntime
    /// Background tabs stay mounted, so without this every world pane ever
    /// opened would keep rendering at the display's full rate.
    var isActive: Bool = true

    func makeNSView(context: Context) -> WorldContainerView {
        let container = WorldContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1).cgColor
        container.onWindowChange = { [weak runtime, weak container] in
            guard let runtime, let container else { return }
            runtime.attach(to: container)
        }
        runtime.attach(to: container)
        return container
    }

    func updateNSView(_ nsView: WorldContainerView, context: Context) {
        runtime.tabActive = isActive
        runtime.attach(to: nsView)
    }
}

/// The pane's content: the RealityKit host, with a quiet loading state over it
/// until the room has been built and drawn.
struct WorldPaneView: View {
    @ObservedObject var runtime: WorldRuntime
    var isActive: Bool = true
    @Environment(\.palette) private var pal

    var body: some View {
        ZStack {
            WorldHost(runtime: runtime, isActive: isActive)
            if !runtime.isReady {
                VStack(spacing: 10) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(pal.faint)
                        .symbolEffect(.pulse, options: .repeating)
                    Text("opening the den")
                        .font(.system(size: 12))
                        .foregroundStyle(pal.faint2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.05, green: 0.05, blue: 0.08))
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.4), value: runtime.isReady)
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
