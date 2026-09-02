import SwiftUI
import RealityKit
import AppKit
import Metal
import QuartzCore

// MARK: - The agent world
//
// A pane that shows every live agent as a hooded figure in a shared den and
// animates it from what that agent is actually doing. Coarse pane state drives
// the fallback behaviour, and the normalised event stream (AgentSources)
// sharpens it into thinking / tool / network when the agent is one we can read.
//
// The scene lives in WorldScene and renders through a RealityRenderer into a
// Metal layer that this file owns. Frames are asked for from a display link
// at a rate the runtime chooses: 30 a second while the pane is on screen and
// none while hidden. An ambient scene needs no more; the walk cycle and the
// camera drift read the same at 30 as at 120, and the difference is most of a
// core in this process and as much again in WindowServer.

/// The Metal surface the world draws into. Turns drags and scrolls into camera
/// moves and reports size and window changes to the runtime.
final class WorldMetalView: NSView {
    var onOrbit: ((Float) -> Void)?
    var onZoom: ((Float) -> Void)?
    var onMagnify: ((Float) -> Void)?
    var onResize: ((CGSize) -> Void)?
    var onWindowChange: (() -> Void)?

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = MTLCreateSystemDefaultDevice()
        l.pixelFormat = .bgra8Unorm_srgb
        l.framebufferOnly = true
        l.isOpaque = true
        l.backgroundColor = CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1)
        return l
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        syncDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncDrawableSize()
        onWindowChange?()
    }

    private func syncDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        onResize?(bounds.size)
    }

    override func mouseDragged(with event: NSEvent) { onOrbit?(Float(event.deltaX)) }
    /// Scrolling up (fingers up, wheel away) brings the room closer, whether
    /// or not the trackpad is set to natural scrolling; pinching does too.
    override func scrollWheel(with event: NSEvent) {
        var dy = Float(event.scrollingDeltaY)
        if event.isDirectionInvertedFromDevice { dy = -dy }
        if !event.hasPreciseScrollingDeltas { dy *= 4 }
        onZoom?(dy)
    }
    override func magnify(with event: NSEvent) { onMagnify?(Float(event.magnification)) }
}

@MainActor
final class WorldRuntime: ObservableObject {
    let scene: WorldScene
    /// True once the room has been built and drawn; the pane shows a loading
    /// state until then rather than pieces popping in.
    @Published private(set) var isReady = false
    /// The scene's hour when the user has taken the slider; nil follows the clock.
    @Published var timeOverride: Double? { didSet { displayHour = sceneHour } }
    /// The hour the toolbar shows, updated as the clock's minute turns.
    @Published private(set) var displayHour: Double = WorldRuntime.realHour
    var sceneHour: Double { timeOverride ?? Self.realHour }
    static var realHour: Double {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
    }
    private(set) var view: WorldMetalView?
    private weak var container: NSView?
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
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
        // `amux -worldDemo 1` starts every world pane in demo mode, for testing;
        // `-worldHour 18.5` starts it at that time of day
        demoMode = UserDefaults.standard.bool(forKey: "worldDemo")
        let h = UserDefaults.standard.double(forKey: "worldHour")
        if h > 0 { timeOverride = h }

        // Only the roster and phases are pushed from here; all motion runs off
        // the frame loop, so this does not need to run anywhere near frame rate.
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

    }

    deinit {
        timer?.invalidate()
        link?.invalidate()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }

    /// The host gives the runtime its container; the run policy decides whether
    /// frames are drawn into it, and how often.
    func attach(to container: NSView) {
        if container !== self.container {
            // a host being dismantled reports leaving its window after the new
            // host has attached; a container with no window that is not ours
            // is on its way out
            guard container.window != nil || self.container == nil else { return }
            self.container = container
            watchOcclusion(of: container.window)
        }
        let v = view ?? makeView()
        view = v
        if v.superview !== container {
            v.frame = container.bounds
            v.autoresizingMask = [.width, .height]
            container.addSubview(v)
        }
        applyRunPolicy()
    }

    private var windowObserver: NSObjectProtocol?
    private func watchOcclusion(of window: NSWindow?) {
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = window.map { w in
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.applyRunPolicy() } }
        }
    }

    private func makeView() -> WorldMetalView {
        let v = WorldMetalView(frame: .zero)
        v.alphaValue = 0   // fades up once the room has drawn
        v.onOrbit = { [weak self] dx in self?.scene.camera.orbit(byPixels: dx) }
        v.onZoom = { [weak self] dy in self?.scene.camera.zoom(byScrollDelta: dy) }
        v.onMagnify = { [weak self] m in self?.scene.camera.zoom(byFactor: 1 + m) }
        v.onResize = { [weak self] size in self?.scene.viewResized(to: size) }
        v.onWindowChange = { [weak self, weak v] in
            guard let self, let v else { return }
            if let w = v.window { self.watchOcclusion(of: w) }
            self.applyRunPolicy()
        }
        let l = v.displayLink(target: self, selector: #selector(frame(_:)))
        l.isPaused = true
        l.add(to: .main, forMode: .common)
        link = l
        return v
    }

    /// Frames per second while the pane is on screen. The display link is
    /// asked for this rate, but on a ProMotion panel that is advisory, so
    /// frame() paces itself to it as well.
    static let frameRate: Double = 30

    /// One place decides whether frames are drawn: on screen and the tab in
    /// front; hidden, none at all.
    private func applyRunPolicy() {
        guard let container, let link else { return }
        let windowVisible = container.window.map {
            $0.occlusionState.contains(.visible) && $0.isVisible
        } ?? false
        let shouldRun = windowVisible && tabActive
        view?.isHidden = !shouldRun
        guard shouldRun else { link.isPaused = true; return }
        let rate = Float(Self.frameRate)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        if link.isPaused { lastFrame = 0; link.isPaused = false }
    }

    @objc private func frame(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            guard let view, view.window != nil, !view.isHidden else { return }
            let now = link.targetTimestamp
            // hold to the rate even if the link calls more often
            if lastFrame != 0, now - lastFrame < (1.0 / Self.frameRate) * 0.9 { return }
            let dt = lastFrame == 0 ? Float(1.0 / Self.frameRate) : Float(min(0.1, now - lastFrame))
            lastFrame = now
            guard let drawable = view.metalLayer.nextDrawable() else { return }
            let presented = scene.render(into: drawable.texture, dt: dt, hour: Float(sceneHour)) { drawable.present() }
            if !presented {
                // nothing to draw yet (the room is still being built): the
                // loading state is showing, and the drawable goes back unused
            }
        }
    }

    /// The room has drawn: fade the surface up and drop the loading state.
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
        if timeOverride == nil, Int(displayHour * 60) != Int(Self.realHour * 60) { displayHour = Self.realHour }
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
    /// opened would keep drawing.
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

/// The pane's content: the Metal surface, with a quiet loading state over it
/// until the room has been built and drawn.
struct WorldPaneView: View {
    @ObservedObject var runtime: WorldRuntime
    var isActive: Bool = true
    @Environment(\.palette) private var pal

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            WorldHost(runtime: runtime, isActive: isActive)
            if runtime.isReady {
                WorldTimeControl(runtime: runtime)
                    .padding(10)
                    .transition(.opacity)
            }
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

/// The scene's clock, tucked into the corner: a small capsule showing the
/// time, which opens into a slider for scrubbing the day and a way back to
/// the Mac's clock.
struct WorldTimeControl: View {
    @ObservedObject var runtime: WorldRuntime
    @Environment(\.palette) private var pal
    @State private var open = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { open.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text(clockText)
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(runtime.timeOverride == nil ? pal.faint : pal.spot)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Hide the time controls" : "Set the time of day in the den")
            if open {
                Slider(value: Binding(get: { runtime.sceneHour }, set: { runtime.timeOverride = $0 }), in: 0...24)
                    .controlSize(.mini)
                    .frame(width: 120)
                    .help("Time of day in the den; follows your clock until you move it")
                Button("now") { runtime.timeOverride = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(runtime.timeOverride == nil ? pal.faint2 : pal.spot)
                    .disabled(runtime.timeOverride == nil)
                    .help("Follow the clock again")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(pal.panel.opacity(0.88), in: Capsule())
        .overlay(Capsule().strokeBorder(pal.faint2.opacity(0.35), lineWidth: 0.5))
    }

    private var clockText: String {
        let h = runtime.displayHour
        return String(format: "%02d:%02d", Int(h) % 24, Int((h - Double(Int(h))) * 60))
    }
}

