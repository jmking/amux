import Foundation
import SwiftUI
import AppKit
import UserNotifications
import IOKit.pwr_mgt

// MARK: - State types (shared by the engine and the views)

struct GitInfo: Codable, Equatable {
    var branch: String
    var dirty: Int
    var ahead: Int
    var behind: Int
}

struct PaneAgent: Codable, Equatable {
    var kind: String
    var name: String?
    var state: String
}

struct PaneLeaf: Codable, Equatable {
    var paneId: String
    var kind: String        // "term" | "web" | "world"
    var label: String?
    var proc: String?
    var agent: PaneAgent?
    var cwd: String?        // shown in the pane header
    var branch: String?     // git branch for that cwd, when it is a repo

    init(paneId: String, kind: String = "term", label: String? = nil,
         proc: String? = nil, agent: PaneAgent? = nil,
         cwd: String? = nil, branch: String? = nil) {
        self.paneId = paneId
        self.kind = kind
        self.label = label
        self.proc = proc
        self.agent = agent
        self.cwd = cwd
        self.branch = branch
    }
}

indirect enum LayoutNode: Equatable {
    case pane(PaneLeaf)
    case split(dir: String, ratio: Double, a: LayoutNode, b: LayoutNode)

    var paneIds: [String] {
        switch self {
        case .pane(let l): return [l.paneId]
        case .split(_, _, let a, let b): return a.paneIds + b.paneIds
        }
    }

    func leaf(for paneId: String) -> PaneLeaf? {
        switch self {
        case .pane(let l): return l.paneId == paneId ? l : nil
        case .split(_, _, let a, let b): return a.leaf(for: paneId) ?? b.leaf(for: paneId)
        }
    }

    /// Replace the leaf holding `paneId` using `transform`; nil removes it
    /// (collapsing the parent split).
    func rewriting(paneId: String, _ transform: (LayoutNode) -> LayoutNode?) -> LayoutNode? {
        switch self {
        case .pane(let l):
            return l.paneId == paneId ? transform(self) : self
        case .split(let dir, let ratio, let a, let b):
            let na = a.rewriting(paneId: paneId, transform)
            let nb = b.rewriting(paneId: paneId, transform)
            switch (na, nb) {
            case (nil, nil): return nil
            case (let x?, nil): return x
            case (nil, let y?): return y
            case (let x?, let y?): return .split(dir: dir, ratio: ratio, a: x, b: y)
            }
        }
    }

    func updatingRatio(path: String, ratio: Double) -> LayoutNode {
        guard case .split(let dir, let r, let a, let b) = self else { return self }
        if path.isEmpty { return .split(dir: dir, ratio: ratio, a: a, b: b) }
        var comps = path.split(separator: ".").map(String.init)
        let head = comps.removeFirst()
        let rest = comps.joined(separator: ".")
        if head == "a" { return .split(dir: dir, ratio: r, a: a.updatingRatio(path: rest, ratio: ratio), b: b) }
        return .split(dir: dir, ratio: r, a: a, b: b.updatingRatio(path: rest, ratio: ratio))
    }
}

struct TabState: Equatable {
    var id: String
    var label: String
    var cwd: String
    var focusedPaneId: String?
    var zoomedPaneId: String?
    var layout: LayoutNode?
}

struct WorktreeInfo: Codable, Equatable {
    var parentRepo: String
    var path: String
    var branch: String
}

struct WorkspaceState: Equatable {
    var id: String
    var label: String
    var cwd: String
    var git: GitInfo?
    var worktreeInfo: WorktreeInfo?
    var icon: String?
    var focusedTabId: String?
    var tabs: [TabState]
    var nextTabNum = 1
    var nextPaneNum = 1

    var worktree: Bool { worktreeInfo != nil }
}

struct AgentRow: Equatable, Identifiable {
    var paneId: String
    var wsId: String
    var tabId: String
    var workspace: String
    var tab: String
    var kind: String
    var name: String?
    var state: String
    var id: String { paneId }
}

struct ServerState: Equatable {
    var version: String
    var hostname: String
    var focusedWorkspaceId: String?
    var workspaces: [WorkspaceState]
    var agents: [AgentRow]
}

struct NotificationItem: Identifiable, Equatable {
    let id = UUID()
    var paneId: String
    var wsId: String
    var tabId: String
    var kind: String
    var name: String?
    var state: String
    var label: String
    var at: Date

    var title: String { "\(name ?? kind) \(state == "blocked" ? "needs you" : "is done")" }
    var sub: String { "\(label) · \(kind) · \(state)" }
}

// MARK: - Sheets

enum RenameTarget {
    case space(id: String, current: String)
    case tab(id: String, current: String)
    case pane(id: String, current: String)
}

enum ActiveSheet: Identifiable {
    case newSpace
    case startAgent(paneId: String)
    case runCommand(paneId: String)
    case newWorktree(repo: String?)
    case confirmCloseSpace(WorkspaceState)
    case confirmCloseTab(TabState)
    case confirmClosePane(paneId: String, agent: PaneAgent)
    case rename(RenameTarget)
    case spaceEmoji(WorkspaceState)

    var id: String {
        switch self {
        case .newSpace: return "newSpace"
        case .startAgent(let p): return "agent-\(p)"
        case .runCommand(let p): return "run-\(p)"
        case .newWorktree: return "worktree"
        case .confirmCloseSpace(let w): return "closeWs-\(w.id)"
        case .confirmCloseTab(let t): return "closeTab-\(t.id)"
        case .confirmClosePane(let p, _): return "closePane-\(p)"
        case .rename: return "rename"
        case .spaceEmoji(let w): return "emoji-\(w.id)"
        }
    }
}

// MARK: - Agent knowledge

enum Agents {
    // process basename -> agent kind
    static let processMap: [String: String] = [
        "claude": "claude",
        "codex": "codex",
        "rovo": "rovo",
        "acli": "rovo",       // older Rovo installs ran inside Atlassian's acli
    ]
    /// Distinctive path components that identify an agent when its own name is
    /// not argv[0] or argv[1] — a CLI shipped as a script runs as its host
    /// runtime ("node .../@atlassian/rovo-cli/dist/index.js"), so the only
    /// recognisable token is a directory in the path. Matched as whole path
    /// components so that editing a file named after an agent does not count.
    static let pathMarkers: [(marker: String, kind: String)] = [
        ("rovo-cli", "rovo"), ("rovodev", "rovo"), ("rovo-dev", "rovo"),
        ("claude-code", "claude"), ("codex-cli", "codex"),
    ]

    static func markerKind(_ line: Substring) -> String? {
        for (marker, kind) in pathMarkers where line.contains(marker) {
            for token in line.split(separator: " ") {
                for comp in token.split(whereSeparator: { $0 == "/" || $0 == "\\" })
                where comp == marker { return kind }
            }
        }
        return nil
    }

    // agent kind -> launch command (first word must be the executable)
    static let launchMap: [String: String] = [
        "claude": "claude",
        "codex": "codex",
        "rovo": "rovo",
    ]
    static let spinnerRE = try! NSRegularExpression(
        pattern: "[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⣾⣽⣻⢿⡿⣟⣯⣷]|esc to interrupt|\\(esc to|ctrl\\+c to interrupt")
    static let blockedRE = try! NSRegularExpression(
        pattern: "Do you want|Would you like|Allow .{0,40}\\?|Proceed\\?|Continue\\?|\\(y/n\\)|\\[y/n\\]|\\[Y/n\\]|yes/no|❯\\s*1\\.",
        options: [.caseInsensitive])
}

private func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
    re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

let KEYMAP: [String: String] = [
    "enter": "\r", "esc": "\u{1b}", "tab": "\t", "shift+tab": "\u{1b}[Z",
    "up": "\u{1b}[A", "down": "\u{1b}[B", "right": "\u{1b}[C", "left": "\u{1b}[D",
    "ctrl+c": "\u{03}", "ctrl+d": "\u{04}", "ctrl+z": "\u{1a}", "ctrl+l": "\u{0c}",
    "space": " ", "backspace": "\u{7f}",
]

// MARK: - App model / engine
// The engine lives in-process: PTYs, detection, git, persistence, sleep
// assertions. Quitting the app stops every agent (by design).

@MainActor
final class AppModel: ObservableObject {
    @Published var state: ServerState?
    @Published var connected = true
    @Published var notifications: [NotificationItem] = []
    @Published var unseenNotifications = 0
    @Published var activeSheet: ActiveSheet?
    @Published var dragRatios: [String: Double] = [:]
    @Published var agentSortPriority = UserDefaults.standard.bool(forKey: "agentSortPriority") {
        didSet { UserDefaults.standard.set(agentSortPriority, forKey: "agentSortPriority") }
    }
    @Published var lastError: String?
    @Published var paletteOpen = false
    @Published var sidebarCollapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed") {
        didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: "sidebarCollapsed") }
    }

    var runtimes: [String: PaneRuntime] = [:]
    var webRuntimes: [String: WebPaneRuntime] = [:]
    var worldRuntimes: [String: WorldRuntime] = [:]

    // Prototype: normalised activity read from what the agents record about
    // themselves. See AgentSources.swift.
    let eventLog = AgentEventLog()
    private var claudeReaders: [String: ClaudeReader] = [:]
    private var codexReaders: [String: CodexReader] = [:]
    var currentDragPayload: String?
    @Published var dragActive = false

    /// Window-space frames of every pane, republished from each pane's layout.
    /// Not @Published: it is written during view update and only ever read by
    /// the drop tracker below.
    var paneFrames: [String: CGRect] = [:]
    /// Drop target chosen by our own tracking rather than by AppKit. Only web
    /// panes use this; see `startDropTracking`.
    @Published var trackedDropPane: String?
    @Published var trackedDropEdge: String?
    private var dropTracker: Timer?
    private var dragWatch: Timer?

    /// Called from every onDrag: while a drag is in flight, web panes float an
    /// invisible drop-catcher so WKWebView can't claim the session.
    func beginDrag(_ payload: String) {
        currentDragPayload = payload
        dragActive = true
        startDropTracking()
        dragWatch?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            if NSEvent.pressedMouseButtons & 1 == 0 {
                timer.invalidate()
                Task { @MainActor in self?.finishTrackedDrop() }
            }
        }
        // .common so it keeps firing inside AppKit's modal drag tracking loop
        RunLoop.main.add(timer, forMode: .common)
        dragWatch = timer
    }

    /// Called the moment a drop completes so highlights clear immediately
    /// instead of waiting for the mouse-up watchdog.
    func endDrag() {
        dragWatch?.invalidate()
        dragWatch = nil
        dropTracker?.invalidate()
        dropTracker = nil
        dragActive = false
        trackedDropPane = nil
        trackedDropEdge = nil
        currentDragPayload = nil
    }

    // MARK: drop tracking
    //
    // Panes do their own drop targeting rather than using SwiftUI's .onDrop.
    //
    // AppKit will not route a drag into the region a WKWebView occupies: the
    // web view wins the hit test, and nothing registered above or around it
    // receives the dragging messages, not a sibling overlay, not the container
    // that owns the web view, and not SwiftUI's own drop view, which never even
    // sees a validateDrop for that pane. Dragging out of a browser pane failed
    // the same way, so a browser could be neither a drop source nor a target.
    //
    // SwiftUI's .onDrop does work for terminal panes, but running two
    // mechanisms means two sets of behaviour to keep in step, so panes use this
    // one path. The drag is bracketed by beginDrag/endDrag, and a timer in
    // .common mode keeps ticking inside AppKit's modal drag loop, so we can
    // follow the pointer, highlight the edge under it, and apply the move when
    // the button comes up. The tab bar keeps its own .onDrop: it is ordinary
    // SwiftUI and sits outside every pane frame, so the two never overlap.

    private func startDropTracking() {
        dropTracker?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTrackedDrop() }
        }
        RunLoop.main.add(t, forMode: .common)
        dropTracker = t
    }

    /// The mouse in the same space as `paneFrames` (SwiftUI's .global, which is
    /// the window's content view with a top-left origin).
    private func pointerInWindow() -> CGPoint? {
        guard let win = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let content = win.contentView else { return nil }
        let p = win.convertPoint(fromScreen: NSEvent.mouseLocation)
        return CGPoint(x: p.x, y: content.bounds.height - p.y)
    }

    private func edgeFor(_ point: CGPoint, in frame: CGRect) -> String {
        let fx = (point.x - frame.minX) / max(frame.width, 1)
        let fy = (point.y - frame.minY) / max(frame.height, 1)
        if fx > 0.3 && fx < 0.7 && fy > 0.3 && fy < 0.7 { return "center" }
        let candidates: [(String, CGFloat)] = [
            ("left", fx), ("right", 1 - fx), ("up", fy), ("down", 1 - fy),
        ]
        return candidates.min { $0.1 < $1.1 }!.0
    }

    private func pane(at point: CGPoint) -> (String, CGRect)? {
        guard let tab = focusedTab else { return nil }
        if let zoomed = tab.zoomedPaneId {
            guard let f = paneFrames[zoomed], f.contains(point) else { return nil }
            return (zoomed, f)
        }
        for paneId in tab.layout?.paneIds ?? [] {
            guard let f = paneFrames[paneId], f.contains(point) else { continue }
            return (paneId, f)
        }
        return nil
    }

    private func updateTrackedDrop() {
        guard dragActive, let p = pointerInWindow() else { return }
        // Short and lightly damped: the highlight should chase the pointer
        // between edges without feeling loose.
        let motion = SwiftUI.Animation.spring(response: 0.17, dampingFraction: 0.82)
        if let (paneId, frame) = pane(at: p) {
            let e = edgeFor(p, in: frame)
            if trackedDropPane != paneId || trackedDropEdge != e {
                withAnimation(motion) {
                    trackedDropPane = paneId
                    trackedDropEdge = e
                }
            }
        } else if trackedDropPane != nil {
            withAnimation(motion) {
                trackedDropPane = nil
                trackedDropEdge = nil
            }
        }
    }

    private func finishTrackedDrop() {
        let target = trackedDropPane
        let edge = trackedDropEdge
        let payload = currentDragPayload
        dropTracker?.invalidate()
        dropTracker = nil
        dragActive = false
        trackedDropPane = nil
        trackedDropEdge = nil
        currentDragPayload = nil
        guard let target, let edge, let payload else { return }
        // Panes are laid out with animatable frame and offset, so animating the
        // tree rewrite makes them slide into their new places. Kept brief: the
        // panes resize as they move, and a terminal resize is not free.
        let settle = SwiftUI.Animation.spring(response: 0.28, dampingFraction: 0.86)
        if payload.hasPrefix("pane:") {
            let src = String(payload.dropFirst(5))
            guard src != target else { return }
            withAnimation(settle) {
                if edge == "center" { swapPanes(src, target) }
                else { movePane(src, toEdge: edge, of: target) }
            }
        } else if payload.hasPrefix("tab:") {
            withAnimation(settle) {
                mergeTab(String(payload.dropFirst(4)),
                         toEdge: edge == "center" ? "right" : edge, of: target)
            }
        }
    }

    /// Pane commands should still work when nothing has been clicked yet.
    var actionPaneId: String? {
        focusedTab?.focusedPaneId ?? focusedTab?.layout?.paneIds.first
    }
    private var lastFocusedPaneId: String?

    // engine state
    private(set) var workspaces: [WorkspaceState] = []
    private var focusedWorkspaceId: String?
    private var nextWorkspaceNum = 1
    private var detectTimer: Timer?
    private var gitTimer: Timer?
    private var saveWork: DispatchWorkItem?
    private var sleepAssertion: IOPMAssertionID = 0
    /// git branch per directory, refreshed on the git tick and shared by every
    /// pane sitting in that directory (usually one lookup for a whole space)
    private var branchByDir: [String: String] = [:]
    private var detectBusy = false

    static let version = "0.2.0"

    // ProcessInfo.hostName does blocking DNS — this doesn't
    static let cachedHostname: String = {
        var buf = [CChar](repeating: 0, count: 256)
        gethostname(&buf, 255)
        return String(cString: buf).components(separatedBy: ".").first ?? "mac"
    }()
    static var stateFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/amux/state.json")
    }
    static var legacyStateFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/gerdr/state.json")
    }

    // MARK: lifecycle

    private var started = false

    func start() {

        guard !started else { return }
        started = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        installFocusMonitor()
        restoreState()
        publish()
        detectTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.detectTick() }
        }
        gitTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.gitTick() }
        }
    }

    func shutdown() {
        saveNow()
        for rt in runtimes.values { rt.terminate() }
        releaseSleepAssertion()
    }

    private func installFocusMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            let window = event.window
            let point = event.locationInWindow
            DispatchQueue.main.async { self?.handleClick(window: window, point: point) }
            return event
        }
    }

    /// Clicking anywhere inside a pane hands both engine focus AND keyboard
    /// focus to its terminal — never rely on AppKit's default click-to-key.
    private func handleClick(window: NSWindow?, point: NSPoint) {
        guard let window, let hit = window.contentView?.hitTest(point) else { return }
        for (paneId, wrt) in webRuntimes {
            guard hit === wrt.view || hit.isDescendant(of: wrt.view) else { continue }
            for ws in workspaces {
                for tab in ws.tabs where tab.layout?.leaf(for: paneId) != nil {
                    if tab.focusedPaneId != paneId || ws.focusedTabId != tab.id
                        || focusedWorkspaceId != ws.id {
                        focus(workspaceId: ws.id, tabId: tab.id, paneId: paneId)
                    }
                    return
                }
            }
            return
        }
        for (paneId, rt) in runtimes {
            guard hit === rt.view || hit.isDescendant(of: rt.view) else { continue }
            if window.firstResponder !== rt.view {
                window.makeFirstResponder(rt.view)
            }
            for ws in workspaces {
                for tab in ws.tabs where tab.layout?.leaf(for: paneId) != nil {
                    if tab.focusedPaneId != paneId || ws.focusedTabId != tab.id
                        || focusedWorkspaceId != ws.id {
                        focus(workspaceId: ws.id, tabId: tab.id, paneId: paneId)
                    }
                    return
                }
            }
            return
        }
    }

    // MARK: publishing

    private func wsIndex(_ id: String?) -> Int? { workspaces.firstIndex { $0.id == id } }

    private func publish() {
        // a publish should never cost a frame; shout if it ever does
        let __t0 = CFAbsoluteTimeGetCurrent()
        defer {
            let ms = (CFAbsoluteTimeGetCurrent() - __t0) * 1000
            if ms > 16 {
                FileHandle.standardError.write(
                    "amux: slow publish \(String(format: "%.1f", ms))ms\n".data(using: .utf8)!)
            }
        }
        for wi in workspaces.indices {
            for ti in workspaces[wi].tabs.indices {
                if let layout = workspaces[wi].tabs[ti].layout {
                    workspaces[wi].tabs[ti].layout = decorate(layout)
                }
            }
        }
        state = ServerState(
            version: Self.version,
            hostname: Self.cachedHostname,
            focusedWorkspaceId: focusedWorkspaceId,
            workspaces: workspaces,
            agents: agentRows())
        followFocus()
        scheduleSave()
    }

    private func decorate(_ node: LayoutNode) -> LayoutNode {
        switch node {
        case .pane(var leaf):
            if leaf.kind == "web" {
                if let wrt = webRuntimes[leaf.paneId] {
                    leaf.label = wrt.title
                    leaf.proc = "web"
                }
            } else if let rt = runtimes[leaf.paneId] {
                leaf.label = rt.label
                leaf.proc = rt.procName
                leaf.agent = rt.agent
                leaf.cwd = rt.cachedCwd
                leaf.branch = rt.cachedCwd.flatMap { branchByDir[$0] }
            }
            return .pane(leaf)
        case .split(let dir, let ratio, let a, let b):
            return .split(dir: dir, ratio: ratio, a: decorate(a), b: decorate(b))
        }
    }

    private func agentRows() -> [AgentRow] {
        var rows: [AgentRow] = []
        for ws in workspaces {
            for tab in ws.tabs {
                for paneId in tab.layout?.paneIds ?? [] {
                    if let rt = runtimes[paneId], let agent = rt.agent {
                        rows.append(AgentRow(
                            paneId: paneId, wsId: ws.id, tabId: tab.id,
                            workspace: ws.label, tab: tab.label,
                            kind: agent.kind, name: agent.name, state: agent.state))
                    }
                }
            }
        }
        return rows
    }

    // MARK: derived

    var focusedWorkspace: WorkspaceState? {
        workspaces.first { $0.id == focusedWorkspaceId }
    }

    var focusedTab: TabState? {
        guard let ws = focusedWorkspace else { return nil }
        return ws.tabs.first { $0.id == ws.focusedTabId }
    }

    func workspaceAggregateState(_ ws: WorkspaceState) -> String {
        let rows = (state?.agents ?? []).filter { $0.wsId == ws.id }
        if rows.contains(where: { $0.state == "blocked" }) { return "blocked" }
        if rows.contains(where: { $0.state == "working" }) { return "working" }
        if rows.contains(where: { $0.state == "done" }) { return "done" }
        return rows.isEmpty ? "unknown" : "idle"
    }

    var busyAgentCount: Int {
        (state?.agents ?? []).filter { $0.state == "working" || $0.state == "blocked" }.count
    }

    // MARK: pane runtime plumbing

    func terminal(for paneId: String) -> PaneRuntime {
        if let rt = runtimes[paneId] { return rt }
        let rt = PaneRuntime(id: paneId, cwd: NSHomeDirectory(), model: self)
        runtimes[paneId] = rt
        return rt
    }

    private func makePane(ws: inout WorkspaceState, cwd: String) -> String {
        let id = "\(ws.id):p\(ws.nextPaneNum)"
        ws.nextPaneNum += 1
        let rt = PaneRuntime(id: id, cwd: cwd, model: self)
        runtimes[id] = rt
        return id
    }

    private func makeWebPane(ws: inout WorkspaceState, url: URL?) -> String {
        let id = "\(ws.id):p\(ws.nextPaneNum)"
        ws.nextPaneNum += 1
        webRuntimes[id] = WebPaneRuntime(id: id, url: url, model: self)
        return id
    }

    func webRuntime(for paneId: String) -> WebPaneRuntime {
        if let rt = webRuntimes[paneId] { return rt }
        let rt = WebPaneRuntime(id: paneId, url: nil, model: self)
        webRuntimes[paneId] = rt
        return rt
    }

    private var webPublishPending = false
    /// Coalesced: a page in a redirect or refresh loop can finish navigations
    /// many times a second, and each publish re-evaluates the whole app,
    /// menu bar included. One publish per 100ms is plenty for a title update.
    func webPaneChanged() {
        guard !webPublishPending else { return }
        webPublishPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.webPublishPending = false
            self?.publish()
        }
    }

    func worldRuntime(for paneId: String) -> WorldRuntime {
        if let rt = worldRuntimes[paneId] { return rt }
        let rt = WorldRuntime(model: self)
        worldRuntimes[paneId] = rt
        return rt
    }

    /// Prototype affordance: cycle fake agents through every behaviour in every
    /// open world pane, so the visualisation can be reviewed without standing up
    /// five real agents.
    func toggleWorldDemo() {
        let on = !(worldRuntimes.values.first?.demoMode ?? false)
        for rt in worldRuntimes.values { rt.demoMode = on }
    }

    /// Opens the agent world as a new tab in the focused space.
    func newWorldTab() {
        guard let wsId = focusedWorkspace?.id, let wi = wsIndex(wsId) else { return }
        var ws = workspaces[wi]
        var tab = TabState(id: "\(ws.id):t\(ws.nextTabNum)", label: "World",
                           cwd: ws.cwd, focusedPaneId: nil, zoomedPaneId: nil, layout: nil)
        ws.nextTabNum += 1
        let paneId = "\(ws.id):p\(ws.nextPaneNum)"
        ws.nextPaneNum += 1
        tab.layout = .pane(PaneLeaf(paneId: paneId, kind: "world"))
        tab.focusedPaneId = paneId
        ws.tabs.append(tab)
        ws.focusedTabId = tab.id
        workspaces[wi] = ws
        focusedWorkspaceId = ws.id
        publish()
    }

    /// cmux-style: a browser opens as a new tab in the focused space.
    func newBrowserTab(url: URL? = nil) {
        guard let wsId = focusedWorkspace?.id, let wi = wsIndex(wsId) else { return }
        var ws = workspaces[wi]
        var tab = TabState(id: "\(ws.id):t\(ws.nextTabNum)", label: "New tab",
                           cwd: ws.cwd, focusedPaneId: nil, zoomedPaneId: nil, layout: nil)
        ws.nextTabNum += 1
        let paneId = makeWebPane(ws: &ws, url: url)
        tab.layout = .pane(PaneLeaf(paneId: paneId, kind: "web"))
        tab.focusedPaneId = paneId
        ws.tabs.append(tab)
        ws.focusedTabId = tab.id
        workspaces[wi] = ws
        publish()
    }

    /// Browser as a split next to an existing pane (agent left, preview right).
    @discardableResult
    func splitPaneWithBrowser(_ paneId: String, direction: String) -> String? {
        guard let (wi, ti) = locate(paneId) else { return nil }
        var ws = workspaces[wi]
        let newId = makeWebPane(ws: &ws, url: nil)
        let dir = direction == "down" ? "column" : "row"
        ws.tabs[ti].layout = ws.tabs[ti].layout?.rewriting(paneId: paneId) { old in
            .split(dir: dir, ratio: 0.5, a: old, b: .pane(PaneLeaf(paneId: newId, kind: "web")))
        }
        ws.tabs[ti].focusedPaneId = newId
        workspaces[wi] = ws
        publish()
        return newId
    }

    func paneExited(_ paneId: String) {
        runtimes.removeValue(forKey: paneId)
        removePaneFromLayout(paneId)
        publish()
    }

    // MARK: workspace / tab / pane ops

    func createWorkspace(label: String?, cwd: String) {
        let dir = (cwd as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            lastError = "directory not found: \(dir)"
            return
        }
        var ws = WorkspaceState(
            id: "w\(nextWorkspaceNum)",
            label: (label?.isEmpty ?? true) ? (dir as NSString).lastPathComponent : label!,
            cwd: dir, git: nil, worktreeInfo: nil, icon: nil, focusedTabId: nil, tabs: [])
        nextWorkspaceNum += 1
        var tab = TabState(id: "\(ws.id):t\(ws.nextTabNum)", label: "main", cwd: dir,
                           focusedPaneId: nil, zoomedPaneId: nil, layout: nil)
        ws.nextTabNum += 1
        let paneId = makePane(ws: &ws, cwd: dir)
        tab.layout = .pane(PaneLeaf(paneId: paneId))
        tab.focusedPaneId = paneId
        ws.focusedTabId = tab.id
        ws.tabs = [tab]
        workspaces.append(ws)
        focusedWorkspaceId = ws.id
        publish()
        gitTick()
    }

    func newTab(_ wsIn: WorkspaceState) {
        guard let wi = wsIndex(wsIn.id) else { return }
        var ws = workspaces[wi]
        var tab = TabState(id: "\(ws.id):t\(ws.nextTabNum)", label: "tab \(ws.tabs.count + 1)",
                           cwd: ws.cwd, focusedPaneId: nil, zoomedPaneId: nil, layout: nil)
        ws.nextTabNum += 1
        let paneId = makePane(ws: &ws, cwd: ws.cwd)
        tab.layout = .pane(PaneLeaf(paneId: paneId))
        tab.focusedPaneId = paneId
        ws.tabs.append(tab)
        ws.focusedTabId = tab.id
        workspaces[wi] = ws
        publish()
    }

    @discardableResult
    func splitPane(_ paneId: String, direction: String) -> String? {
        guard let (wi, ti) = locate(paneId) else { return nil }
        var ws = workspaces[wi]
        let cwd = runtimes[paneId]?.currentCwd() ?? ws.tabs[ti].cwd
        let newId = makePane(ws: &ws, cwd: cwd)
        let dir = direction == "down" ? "column" : "row"
        ws.tabs[ti].layout = ws.tabs[ti].layout?.rewriting(paneId: paneId) { old in
            .split(dir: dir, ratio: 0.5, a: old, b: .pane(PaneLeaf(paneId: newId)))
        }
        ws.tabs[ti].focusedPaneId = newId
        workspaces[wi] = ws
        publish()
        return newId
    }

    private func locate(_ paneId: String) -> (Int, Int)? {
        for wi in workspaces.indices {
            for ti in workspaces[wi].tabs.indices
            where workspaces[wi].tabs[ti].layout?.leaf(for: paneId) != nil {
                return (wi, ti)
            }
        }
        return nil
    }

    func closePane(_ paneId: String) {
        runtimes[paneId]?.terminate()
        runtimes.removeValue(forKey: paneId)
        webRuntimes[paneId]?.detach()
        webRuntimes.removeValue(forKey: paneId)
        worldRuntimes.removeValue(forKey: paneId)
        claudeReaders.removeValue(forKey: paneId)
        codexReaders.removeValue(forKey: paneId)
        paneFrames.removeValue(forKey: paneId)
        removePaneFromLayout(paneId)
        publish()
    }

    private func removePaneFromLayout(_ paneId: String) {
        guard let (wi, ti) = locate(paneId) else { return }
        var ws = workspaces[wi]
        let newLayout = ws.tabs[ti].layout?.rewriting(paneId: paneId) { _ in nil }
        if let newLayout {
            ws.tabs[ti].layout = newLayout
            if ws.tabs[ti].focusedPaneId == paneId { ws.tabs[ti].focusedPaneId = newLayout.paneIds.first }
            if ws.tabs[ti].zoomedPaneId == paneId { ws.tabs[ti].zoomedPaneId = nil }
            workspaces[wi] = ws
        } else {
            ws.tabs.remove(at: ti)
            if !ws.tabs.contains(where: { $0.id == ws.focusedTabId }) { ws.focusedTabId = ws.tabs.first?.id }
            workspaces[wi] = ws
            if ws.tabs.isEmpty { closeWorkspaceRecord(ws.id) }
        }
    }

    func closeTab(_ tabId: String) {
        guard let wi = workspaces.firstIndex(where: { $0.tabs.contains { $0.id == tabId } }) else { return }
        var ws = workspaces[wi]
        guard let ti = ws.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        for pid in ws.tabs[ti].layout?.paneIds ?? [] {
            runtimes[pid]?.terminate()
            runtimes.removeValue(forKey: pid)
            webRuntimes[pid]?.detach()
            webRuntimes.removeValue(forKey: pid)
            worldRuntimes.removeValue(forKey: pid)
            paneFrames.removeValue(forKey: pid)
        }
        ws.tabs.remove(at: ti)
        if ws.focusedTabId == tabId { ws.focusedTabId = ws.tabs.first?.id }
        workspaces[wi] = ws
        if ws.tabs.isEmpty { closeWorkspaceRecord(ws.id) }
        publish()
    }

    private func closeWorkspaceRecord(_ wsId: String) {
        workspaces.removeAll { $0.id == wsId }
        if focusedWorkspaceId == wsId { focusedWorkspaceId = workspaces.first?.id }
    }

    func closeWorkspace(_ wsId: String, removeWorktree: Bool = false) {
        guard let wi = wsIndex(wsId) else { return }
        let ws = workspaces[wi]
        for tab in ws.tabs {
            for pid in tab.layout?.paneIds ?? [] {
                runtimes[pid]?.terminate()
                runtimes.removeValue(forKey: pid)
                webRuntimes[pid]?.detach()
                webRuntimes.removeValue(forKey: pid)
                worldRuntimes.removeValue(forKey: pid)
                paneFrames.removeValue(forKey: pid)
            }
        }
        closeWorkspaceRecord(wsId)
        if removeWorktree, let wt = ws.worktreeInfo {
            runGit(["-C", wt.parentRepo, "worktree", "remove", "--force", wt.path]) { _, _ in }
        }
        publish()
    }

    func focus(workspaceId: String? = nil, tabId: String? = nil, paneId: String? = nil) {
        if let workspaceId, wsIndex(workspaceId) != nil { focusedWorkspaceId = workspaceId }
        guard let wi = wsIndex(focusedWorkspaceId) else { publish(); return }
        var ws = workspaces[wi]
        if let tabId, ws.tabs.contains(where: { $0.id == tabId }) {
            ws.focusedTabId = tabId
        }
        if let paneId, let ti = ws.tabs.firstIndex(where: { $0.id == ws.focusedTabId }),
           ws.tabs[ti].layout?.leaf(for: paneId) != nil {
            ws.tabs[ti].focusedPaneId = paneId
        }
        workspaces[wi] = ws
        if let focusedTabId = ws.focusedTabId { markTabSeen(focusedTabId) }
        publish()
    }

    private func followFocus() {
        let focused = focusedTab?.focusedPaneId
        guard focused != lastFocusedPaneId else { return }
        lastFocusedPaneId = focused
        guard activeSheet == nil, !paletteOpen else { return }
        if let focused { makeTerminalKey(focused) }
    }

    func makeTerminalKey(_ paneId: String) {
        if let wrt = webRuntimes[paneId] {
            wrt.view.window?.makeFirstResponder(wrt.view)
            return
        }
        guard let rt = runtimes[paneId], let window = rt.view.window else { return }
        window.makeFirstResponder(rt.view)
    }

    func renameSpace(_ id: String, label: String) {
        guard let wi = wsIndex(id) else { return }
        workspaces[wi].label = label
        publish()
    }

    func renameTab(_ id: String, label: String) {
        for wi in workspaces.indices {
            if let ti = workspaces[wi].tabs.firstIndex(where: { $0.id == id }) {
                workspaces[wi].tabs[ti].label = label
                publish()
                return
            }
        }
    }

    func renamePane(_ id: String, label: String) {
        runtimes[id]?.label = label.isEmpty ? nil : label
        publish()
    }

    func setSpaceIcon(_ wsId: String, icon: String?) {
        guard let wi = wsIndex(wsId) else { return }
        workspaces[wi].icon = (icon?.isEmpty ?? true) ? nil : icon
        publish()
    }

    func setRatio(tabId: String, path: String, ratio: Double) {
        for wi in workspaces.indices {
            if let ti = workspaces[wi].tabs.firstIndex(where: { $0.id == tabId }) {
                workspaces[wi].tabs[ti].layout =
                    workspaces[wi].tabs[ti].layout?.updatingRatio(path: path, ratio: min(0.9, max(0.1, ratio)))
                publish()
                return
            }
        }
    }

    func zoomPane(_ paneId: String) {
        guard let (wi, ti) = locate(paneId) else { return }
        workspaces[wi].tabs[ti].zoomedPaneId =
            workspaces[wi].tabs[ti].zoomedPaneId == paneId ? nil : paneId
        publish()
    }

    // MARK: moves / swaps / merges

    func movePane(_ paneId: String, toEdge edge: String, of targetPaneId: String) {
        guard paneId != targetPaneId, let (swi, sti) = locate(paneId),
              let leaf = workspaces[swi].tabs[sti].layout?.leaf(for: paneId) else { return }
        detachLeaf(paneId)
        guard let (twi, tti) = locate(targetPaneId) else { publish(); return }
        var ws = workspaces[twi]
        let dir = (edge == "left" || edge == "right") ? "row" : "column"
        let movedFirst = (edge == "left" || edge == "up")
        ws.tabs[tti].layout = ws.tabs[tti].layout?.rewriting(paneId: targetPaneId) { old in
            .split(dir: dir, ratio: 0.5,
                   a: movedFirst ? .pane(leaf) : old,
                   b: movedFirst ? old : .pane(leaf))
        }
        ws.tabs[tti].focusedPaneId = paneId
        workspaces[twi] = ws
        publish()
    }

    func movePane(_ paneId: String, toTab tabId: String) {
        guard let (swi, sti) = locate(paneId),
              workspaces[swi].tabs[sti].id != tabId,
              let leaf = workspaces[swi].tabs[sti].layout?.leaf(for: paneId) else { return }
        detachLeaf(paneId)
        guard let twi = workspaces.firstIndex(where: { $0.tabs.contains { $0.id == tabId } }),
              let tti = workspaces[twi].tabs.firstIndex(where: { $0.id == tabId }) else { publish(); return }
        var ws = workspaces[twi]
        ws.tabs[tti].layout = ws.tabs[tti].layout.map {
            .split(dir: "row", ratio: 0.5, a: $0, b: .pane(leaf))
        } ?? .pane(leaf)
        ws.tabs[tti].focusedPaneId = paneId
        workspaces[twi] = ws
        publish()
    }

    func movePane(_ paneId: String, toWorkspace wsId: String) {
        guard let (swi, sti) = locate(paneId),
              let leaf = workspaces[swi].tabs[sti].layout?.leaf(for: paneId) else { return }
        detachLeaf(paneId)
        guard let wi = wsIndex(wsId) else { publish(); return }
        var ws = workspaces[wi]
        let tab = TabState(id: "\(ws.id):t\(ws.nextTabNum)",
                           label: runtimes[paneId]?.label ?? "moved",
                           cwd: ws.cwd, focusedPaneId: paneId, zoomedPaneId: nil,
                           layout: .pane(leaf))
        ws.nextTabNum += 1
        ws.tabs.append(tab)
        ws.focusedTabId = tab.id
        workspaces[wi] = ws
        publish()
    }

    /// Remove a pane's leaf without killing the pty (for moves).
    private func detachLeaf(_ paneId: String) {
        guard let (wi, ti) = locate(paneId) else { return }
        var ws = workspaces[wi]
        let newLayout = ws.tabs[ti].layout?.rewriting(paneId: paneId) { _ in nil }
        if let newLayout {
            ws.tabs[ti].layout = newLayout
            if ws.tabs[ti].focusedPaneId == paneId { ws.tabs[ti].focusedPaneId = newLayout.paneIds.first }
            if ws.tabs[ti].zoomedPaneId == paneId { ws.tabs[ti].zoomedPaneId = nil }
            workspaces[wi] = ws
        } else {
            ws.tabs.remove(at: ti)
            if !ws.tabs.contains(where: { $0.id == ws.focusedTabId }) { ws.focusedTabId = ws.tabs.first?.id }
            workspaces[wi] = ws
            if ws.tabs.isEmpty && workspaces.count > 1 { closeWorkspaceRecord(ws.id) }
        }
    }

    func mergeTab(_ tabId: String, toEdge edge: String, of targetPaneId: String) {
        guard let swi = workspaces.firstIndex(where: { $0.tabs.contains { $0.id == tabId } }),
              let sti = workspaces[swi].tabs.firstIndex(where: { $0.id == tabId }),
              let subtree = workspaces[swi].tabs[sti].layout else { return }
        guard let (twi0, tti0) = locate(targetPaneId),
              workspaces[twi0].tabs[tti0].id != tabId else { return }
        var sws = workspaces[swi]
        sws.tabs.remove(at: sti)
        if !sws.tabs.contains(where: { $0.id == sws.focusedTabId }) { sws.focusedTabId = sws.tabs.first?.id }
        workspaces[swi] = sws
        if sws.tabs.isEmpty && workspaces.count > 1 && sws.id != workspaces[twi0].id {
            closeWorkspaceRecord(sws.id)
        }
        guard let (twi, tti) = locate(targetPaneId) else { publish(); return }
        var ws = workspaces[twi]
        let e = edge == "center" ? "right" : edge
        let dir = (e == "left" || e == "right") ? "row" : "column"
        let movedFirst = (e == "left" || e == "up")
        ws.tabs[tti].layout = ws.tabs[tti].layout?.rewriting(paneId: targetPaneId) { old in
            .split(dir: dir, ratio: 0.5,
                   a: movedFirst ? subtree : old,
                   b: movedFirst ? old : subtree)
        }
        workspaces[twi] = ws
        publish()
    }

    func swapPanes(_ a: String, _ b: String) {
        guard a != b,
              let (awi, ati) = locate(a), let (bwi, bti) = locate(b),
              let leafA = workspaces[awi].tabs[ati].layout?.leaf(for: a),
              let leafB = workspaces[bwi].tabs[bti].layout?.leaf(for: b) else { return }

        // Both leaves must be exchanged in ONE traversal: rewriting them one at a
        // time makes the first write's new id match the second rewrite, which
        // duplicates a pane and orphans the other.
        func exchange(_ node: LayoutNode) -> LayoutNode {
            switch node {
            case .pane(let leaf):
                if leaf.paneId == a { return .pane(leafB) }
                if leaf.paneId == b { return .pane(leafA) }
                return node
            case .split(let dir, let ratio, let x, let y):
                return .split(dir: dir, ratio: ratio, a: exchange(x), b: exchange(y))
            }
        }

        if awi == bwi && ati == bti {
            workspaces[awi].tabs[ati].layout = workspaces[awi].tabs[ati].layout.map(exchange)
        } else {
            workspaces[awi].tabs[ati].layout = workspaces[awi].tabs[ati].layout.map(exchange)
            workspaces[bwi].tabs[bti].layout = workspaces[bwi].tabs[bti].layout.map(exchange)
            if workspaces[awi].tabs[ati].focusedPaneId == a { workspaces[awi].tabs[ati].focusedPaneId = b }
            if workspaces[bwi].tabs[bti].focusedPaneId == b { workspaces[bwi].tabs[bti].focusedPaneId = a }
        }
        publish()
    }

    func moveTab(_ tabId: String, toIndex: Int) {
        guard let wi = workspaces.firstIndex(where: { $0.tabs.contains { $0.id == tabId } }),
              let ti = workspaces[wi].tabs.firstIndex(where: { $0.id == tabId }) else { return }
        var ws = workspaces[wi]
        let tab = ws.tabs.remove(at: ti)
        ws.tabs.insert(tab, at: max(0, min(ws.tabs.count, toIndex)))
        workspaces[wi] = ws
        publish()
    }

    // MARK: tab / space navigation

    func selectTab(index: Int) {
        guard let ws = focusedWorkspace, index < ws.tabs.count else { return }
        focus(workspaceId: ws.id, tabId: ws.tabs[index].id)
    }

    func stepTab(_ delta: Int) {
        guard let ws = focusedWorkspace, !ws.tabs.isEmpty,
              let i = ws.tabs.firstIndex(where: { $0.id == ws.focusedTabId }) else { return }
        let n = (i + delta + ws.tabs.count) % ws.tabs.count
        focus(workspaceId: ws.id, tabId: ws.tabs[n].id)
    }

    func selectSpace(index: Int) {
        guard index < workspaces.count else { return }
        focus(workspaceId: workspaces[index].id)
    }

    func focusDirection(_ dir: String) {
        guard let ws = focusedWorkspace, let tab = focusedTab, let layout = tab.layout,
              let current = tab.focusedPaneId else { return }
        var rects: [String: CGRect] = [:]
        collectUnitRects(layout, CGRect(x: 0, y: 0, width: 1, height: 1), &rects)
        guard let cur = rects[current] else { return }
        var best: (id: String, dist: CGFloat)? = nil
        for (id, r) in rects where id != current {
            let ok: Bool
            switch dir {
            case "left": ok = r.maxX <= cur.minX + 0.001 && overlaps(r.minY...r.maxY, cur.minY...cur.maxY)
            case "right": ok = r.minX >= cur.maxX - 0.001 && overlaps(r.minY...r.maxY, cur.minY...cur.maxY)
            case "up": ok = r.maxY <= cur.minY + 0.001 && overlaps(r.minX...r.maxX, cur.minX...cur.maxX)
            default: ok = r.minY >= cur.maxY - 0.001 && overlaps(r.minX...r.maxX, cur.minX...cur.maxX)
            }
            if ok {
                let d = abs(r.midX - cur.midX) + abs(r.midY - cur.midY)
                if best == nil || d < best!.dist { best = (id, d) }
            }
        }
        if let best { focus(workspaceId: ws.id, tabId: tab.id, paneId: best.id) }
    }

    private func overlaps(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> Bool {
        a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }

    private func collectUnitRects(_ node: LayoutNode, _ rect: CGRect, _ out: inout [String: CGRect]) {
        switch node {
        case .pane(let leaf):
            out[leaf.paneId] = rect
        case .split(let dir, let ratio, let a, let b):
            if dir == "row" {
                let w = rect.width * ratio
                collectUnitRects(a, CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height), &out)
                collectUnitRects(b, CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height), &out)
            } else {
                let h = rect.height * ratio
                collectUnitRects(a, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h), &out)
                collectUnitRects(b, CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h), &out)
            }
        }
    }

    // MARK: terminal input ops

    func runCommand(_ paneId: String, command: String) {
        runtimes[paneId]?.sendText(command + "\r")
    }

    func sendKeys(_ paneId: String, keys: [String]) {
        for k in keys {
            if let seq = KEYMAP[k] { runtimes[paneId]?.sendText(seq) }
        }
    }

    func startAgent(paneId: String, kind: String, name: String?, args: String) {
        guard let exe = Agents.launchMap[kind], let rt = runtimes[paneId] else { return }
        let trimmed = args.trimmingCharacters(in: .whitespaces)
        rt.sendText(exe + (trimmed.isEmpty ? "" : " " + trimmed) + "\r")
        if let name, !name.isEmpty {
            rt.agent = PaneAgent(kind: kind, name: name, state: "unknown")
        }
        focus(paneId: paneId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.makeTerminalKey(paneId)
        }
    }

    func fetchAgentKinds() async -> [(kind: String, installed: Bool)] {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        var found: [(String, Bool)] = []
        for (kind, command) in Agents.launchMap.sorted(by: { $0.key < $1.key }) {
            let exe = String(command.split(separator: " ").first ?? "")
            let installed = dirs.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + exe) }
            found.append((kind, installed))
        }
        return found.filter { $0.1 } + found.filter { !$0.1 }
    }

    // MARK: worktrees

    func createWorktree(repo: String, branch: String, base: String?) {
        let repoPath = (repo as NSString).expandingTildeInPath
        let wtRoot = NSHomeDirectory() + "/.amux/worktrees"
        try? FileManager.default.createDirectory(atPath: wtRoot, withIntermediateDirectories: true)
        let safe = branch.replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "-", options: .regularExpression)
        let wtPath = wtRoot + "/" + (repoPath as NSString).lastPathComponent + "-" + safe
        runGit(["-C", repoPath, "worktree", "add", "-b", branch, wtPath, base ?? "HEAD"]) { [weak self] ok, output in
            Task { @MainActor in
                guard let self else { return }
                if ok {
                    self.createWorkspace(label: branch, cwd: wtPath)
                    if let wi = self.wsIndex(self.focusedWorkspaceId) {
                        self.workspaces[wi].worktreeInfo =
                            WorktreeInfo(parentRepo: repoPath, path: wtPath, branch: branch)
                        self.publish()
                    }
                } else {
                    self.lastError = output.isEmpty ? "git worktree add failed" : output
                }
            }
        }
    }

    // MARK: agent detection

    private func detectTick() {
        guard !detectBusy else { return }
        detectBusy = true
        let shellPids = runtimes.mapValues { $0.shellPid }
        DispatchQueue.global(qos: .utility).async {
            let table = processTable()
            // one lsof for every pane at once, off the main thread
            let cwds = lsofCwds(Array(shellPids.values.filter { $0 > 0 }))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.detectBusy = false
                for (paneId, pid) in shellPids {
                    if let cwd = cwds[pid] { self.runtimes[paneId]?.cachedCwd = cwd }
                }
                self.applyDetection(table: table, shellPids: shellPids)
                self.pollAgentSources()
            }
        }
    }

    /// Reads whatever the live agents have appended since the last tick. Runs on
    /// a background queue: both readers touch the filesystem, and the perf rule
    /// in this app is that nothing like that happens on the main thread.
    /// All reader IO runs here, serially: the readers mutate unsynchronised
    /// state (tail offsets, pending tool calls), and the concurrent global
    /// queue let two ticks' polls overlap on the same instances.
    private static let pollQueue = DispatchQueue(label: "au.jmk.amux.agent-poll", qos: .utility)

    private func pollAgentSources() {
        let live: [(String, String, String?)] = (state?.agents ?? []).compactMap {
            guard $0.kind == "claude" || $0.kind == "codex" else { return nil }
            return ($0.paneId, $0.kind, runtimes[$0.paneId]?.cachedCwd)
        }
        guard !live.isEmpty else { return }
        for (paneId, kind, _) in live where kind == "claude" && claudeReaders[paneId] == nil {
            claudeReaders[paneId] = ClaudeReader()
        }
        for (paneId, kind, _) in live where kind == "codex" && codexReaders[paneId] == nil {
            codexReaders[paneId] = CodexReader()
        }
        let claude = claudeReaders, codex = codexReaders
        Self.pollQueue.async {
            var batch: [AgentEvent] = []
            for (paneId, kind, cwd) in live {
                if kind == "claude" { batch += claude[paneId]?.poll(paneId: paneId, cwd: cwd) ?? [] }
                else { batch += codex[paneId]?.poll(paneId: paneId, cwd: cwd) ?? [] }
            }
            guard !batch.isEmpty else { return }
            Task { @MainActor [weak self] in self?.eventLog.append(contentsOf: batch) }
        }
    }

    private func applyDetection(table: [pid_t: [PSEntry]], shellPids: [String: pid_t]) {
        var changed = false
        for (paneId, rt) in runtimes {
            guard let shellPid = shellPids[paneId], shellPid > 0 else { continue }
            if let fg = table[shellPid]?.first { rt.procName = fg.base }
            else { rt.procName = "shell" }
            let found = findAgent(table: table, root: shellPid, depth: 0)
            guard let kind = resolveAgent(rt: rt, found: found, table: table,
                                          shellPid: shellPid, changed: &changed) else { continue }
            if rt.agent == nil || rt.agent?.kind != kind {
                rt.agent = PaneAgent(kind: kind, name: rt.agent?.name, state: "unknown")
                changed = true
            }
            let screen = rt.screenTail()
            let recent = Date().timeIntervalSince(rt.lastOutputAt) < 2.5
            var next: String
            if matches(Agents.spinnerRE, screen) { next = "working" }
            else if matches(Agents.blockedRE, screen) { next = "blocked" }
            else if recent { next = "working" }
            else { next = "idle" }

            let prev = rt.agent?.state ?? "unknown"
            if next == "idle" && (prev == "working" || prev == "done") {
                next = isPaneVisibleFocused(paneId) ? "idle" : "done"
            }
            if prev == "done" && next == "idle" && !isPaneVisibleFocused(paneId) { next = "done" }

            if prev != next {
                rt.agent?.state = next
                changed = true
                if (next == "blocked" || next == "done") && !isPaneVisibleFocused(paneId) {
                    notifyAgent(paneId: paneId, rt: rt, newState: next)
                }
            }
        }
        if changed {
            publish()
            updateSleepAssertion()
        }
    }

    /// Decides what agent a pane is running, tolerating ticks where the process
    /// tree cannot name one.
    ///
    /// Agent CLIs are often thin launchers: the wrapper we recognise by name
    /// starts up, hands the session to a long-lived process named after its
    /// host runtime (node, a JVM, a vendor binary), and exits. From then on the
    /// tree carries no recognisable name even though the agent is very much
    /// alive. Dropping on the first miss made those agents flicker into the
    /// list and vanish a second later, which is what Rovo did.
    ///
    /// The tell is whether the pane's shell still has any child at all. A bare
    /// prompt means the agent really did exit, so let go at once and keep the
    /// list honest. A live but unrecognised child means we just cannot name it,
    /// so hold the kind we already established. Note this has to hold for the
    /// whole session rather than a grace period: after a handoff the tree never
    /// becomes recognisable again, so any expiring counter would simply move
    /// the disappearance a few seconds later.
    private func resolveAgent(rt: PaneRuntime, found: String?, table: [pid_t: [PSEntry]],
                              shellPid: pid_t, changed: inout Bool) -> String? {
        if let found { return found }
        guard let known = rt.agent?.kind else { return nil }
        if (table[shellPid] ?? []).isEmpty {
            rt.agent = nil
            changed = true
            return nil
        }
        return known
    }

    private func findAgent(table: [pid_t: [PSEntry]], root: pid_t, depth: Int) -> String? {
        guard depth < 6 else { return nil }
        for child in table[root] ?? [] {
            if let k = child.kind { return k }
            if let deeper = findAgent(table: table, root: child.pid, depth: depth + 1) { return deeper }
        }
        return nil
    }

    private func isPaneVisibleFocused(_ paneId: String) -> Bool {
        guard let (wi, ti) = locate(paneId) else { return false }
        return workspaces[wi].id == focusedWorkspaceId
            && workspaces[wi].tabs[ti].id == workspaces[wi].focusedTabId
    }

    private func markTabSeen(_ tabId: String) {
        for ws in workspaces {
            for tab in ws.tabs where tab.id == tabId {
                for pid in tab.layout?.paneIds ?? [] where runtimes[pid]?.agent?.state == "done" {
                    runtimes[pid]?.agent?.state = "idle"
                }
            }
        }
    }

    private func notifyAgent(paneId: String, rt: PaneRuntime, newState: String) {
        guard let (wi, ti) = locate(paneId) else { return }
        let item = NotificationItem(
            paneId: paneId, wsId: workspaces[wi].id, tabId: workspaces[wi].tabs[ti].id,
            kind: rt.agent?.kind ?? "agent", name: rt.agent?.name, state: newState,
            label: workspaces[wi].label, at: Date())
        notifications.insert(item, at: 0)
        if notifications.count > 50 { notifications.removeLast() }
        unseenNotifications += 1

        // Play the sound ourselves rather than attaching it to the notification:
        // a notification's sound only fires if the user granted Notification
        // Center permission, so a denied prompt silently killed all audio. This
        // way "done" is always audible, and it's a nicer chime than the default.
        if UserDefaults.standard.object(forKey: "notifSounds") as? Bool ?? true {
            let name = newState == "blocked" ? "Submarine" : "Glass"
            NSSound(named: NSSound.Name(name))?.play()
        }

        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.sub
        content.userInfo = ["wsId": item.wsId, "tabId": item.tabId, "paneId": item.paneId]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil))
    }

    func openNotification(_ item: NotificationItem) {
        focus(workspaceId: item.wsId, tabId: item.tabId, paneId: item.paneId)
    }

    func openLatestNotification() {
        if let n = notifications.first { openNotification(n) }
    }

    // MARK: sleep assertion — no idle sleep while agents are working

    private func updateSleepAssertion() {
        let busy = busyAgentCount > 0
        if busy && sleepAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "amux agents are working" as CFString,
                &sleepAssertion)
        } else if !busy && sleepAssertion != 0 {
            releaseSleepAssertion()
        }
    }

    private func releaseSleepAssertion() {
        if sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    // MARK: git polling

    private func gitTick() {
        refreshPaneBranches()
        for ws in workspaces {
            let wsId = ws.id
            let cwd = ws.cwd
            runGit(["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]) { [weak self] ok, branchOut in
                Task { @MainActor in
                    guard let self, let wi = self.wsIndex(wsId) else { return }
                    guard ok else {
                        if self.workspaces[wi].git != nil {
                            self.workspaces[wi].git = nil
                            self.publish()
                        }
                        return
                    }
                    let branch = branchOut.trimmingCharacters(in: .whitespacesAndNewlines)
                    runGit(["-C", cwd, "status", "--porcelain"]) { _, statusOut in
                        let dirty = statusOut.split(separator: "\n").count
                        runGit(["-C", cwd, "rev-list", "--left-right", "--count", "@{u}...HEAD"]) { okAB, abOut in
                            Task { @MainActor in
                                guard let wi2 = self.wsIndex(wsId) else { return }
                                var ahead = 0, behind = 0
                                if okAB {
                                    let parts = abOut.split(whereSeparator: { $0 == "\t" || $0 == " " })
                                        .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                                    if parts.count == 2 { behind = parts[0]; ahead = parts[1] }
                                }
                                let next = GitInfo(branch: branch, dirty: dirty, ahead: ahead, behind: behind)
                                if self.workspaces[wi2].git != next {
                                    self.workspaces[wi2].git = next
                                    self.publish()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// One `git` call per distinct pane directory, not per pane.
    private func refreshPaneBranches() {
        let dirs = Set(runtimes.values.compactMap { $0.cachedCwd })
        for dir in dirs {
            runGit(["-C", dir, "rev-parse", "--abbrev-ref", "HEAD"]) { [weak self] ok, out in
                Task { @MainActor in
                    guard let self else { return }
                    let branch = ok ? out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                    if self.branchByDir[dir] != branch {
                        if let branch { self.branchByDir[dir] = branch }
                        else { self.branchByDir.removeValue(forKey: dir) }
                        self.publish()
                    }
                }
            }
        }
        // drop directories no pane uses any more
        for key in branchByDir.keys where !dirs.contains(key) {
            branchByDir.removeValue(forKey: key)
        }
    }

    // MARK: persistence (same file shape the Node server used)

    private final class DumpNode: Codable {
        var type: String = "pane"
        var paneId: String?
        var kind: String?
        var url: String?
        var cwd: String?
        var label: String?
        var dir: String?
        var ratio: Double?
        var a: DumpNode?
        var b: DumpNode?
    }
    private struct DumpTab: Codable {
        var id: String
        var label: String
        var cwd: String?
        var focusedPaneId: String?
        var layout: DumpNode?
    }
    private struct DumpWs: Codable {
        var id: String
        var label: String
        var cwd: String
        var icon: String?
        var worktree: WorktreeInfo?
        var focusedTabId: String?
        var nextTabNum: Int?
        var nextPaneNum: Int?
        var tabs: [DumpTab]
    }
    private struct Dump: Codable {
        var version: Int
        var nextWorkspaceNum: Int?
        var focusedWorkspaceId: String?
        var workspaces: [DumpWs]
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        let dump = Dump(
            version: 1,
            nextWorkspaceNum: nextWorkspaceNum,
            focusedWorkspaceId: focusedWorkspaceId,
            workspaces: workspaces.map { ws in
                DumpWs(id: ws.id, label: ws.label, cwd: ws.cwd, icon: ws.icon,
                       worktree: ws.worktreeInfo, focusedTabId: ws.focusedTabId,
                       nextTabNum: ws.nextTabNum, nextPaneNum: ws.nextPaneNum,
                       tabs: ws.tabs.map { tab in
                           DumpTab(id: tab.id, label: tab.label, cwd: tab.cwd,
                                   focusedPaneId: tab.focusedPaneId,
                                   layout: dumpNode(tab.layout))
                       })
            })
        let dir = Self.stateFile.deletingLastPathComponent()
        let file = Self.stateFile
        guard let data = try? JSONEncoder().encode(dump) else { return }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: file)
        }
    }

    private func dumpNode(_ node: LayoutNode?) -> DumpNode? {
        guard let node else { return nil }
        let d = DumpNode()
        switch node {
        case .pane(let leaf):
            d.type = "pane"
            d.paneId = leaf.paneId
            d.kind = leaf.kind
            if leaf.kind == "web" {
                d.url = webRuntimes[leaf.paneId]?.url?.absoluteString
            } else {
                d.cwd = runtimes[leaf.paneId]?.currentCwd()
                d.label = runtimes[leaf.paneId]?.label
            }
        case .split(let dir, let ratio, let a, let b):
            d.type = "split"
            d.dir = dir
            d.ratio = ratio
            d.a = dumpNode(a)
            d.b = dumpNode(b)
        }
        return d
    }

    private func restoreState() {
        let data = (try? Data(contentsOf: Self.stateFile))
            ?? (try? Data(contentsOf: Self.legacyStateFile))
        guard let data, let dump = try? JSONDecoder().decode(Dump.self, from: data) else { return }
        nextWorkspaceNum = dump.nextWorkspaceNum ?? 1
        for dws in dump.workspaces {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dws.cwd, isDirectory: &isDir), isDir.boolValue else { continue }
            var ws = WorkspaceState(
                id: dws.id, label: dws.label, cwd: dws.cwd, git: nil,
                worktreeInfo: dws.worktree, icon: dws.icon, focusedTabId: nil, tabs: [])
            ws.nextTabNum = dws.nextTabNum ?? 1
            ws.nextPaneNum = dws.nextPaneNum ?? 1
            for dtab in dws.tabs {
                var tab = TabState(id: dtab.id, label: dtab.label, cwd: dtab.cwd ?? dws.cwd,
                                   focusedPaneId: nil, zoomedPaneId: nil, layout: nil)
                tab.layout = restoreNode(dtab.layout, ws: &ws)
                guard tab.layout != nil else { continue }
                let ids = tab.layout?.paneIds ?? []
                tab.focusedPaneId = ids.contains(dtab.focusedPaneId ?? "") ? dtab.focusedPaneId : ids.first
                ws.tabs.append(tab)
            }
            ws.focusedTabId = ws.tabs.contains { $0.id == dws.focusedTabId } ? dws.focusedTabId : ws.tabs.first?.id
            guard !ws.tabs.isEmpty else { continue }
            workspaces.append(ws)
        }
        focusedWorkspaceId = workspaces.contains { $0.id == dump.focusedWorkspaceId }
            ? dump.focusedWorkspaceId : workspaces.first?.id
        gitTick()
    }

    private func restoreNode(_ node: DumpNode?, ws: inout WorkspaceState) -> LayoutNode? {
        guard let node else { return nil }
        if node.type == "pane" {
            guard let paneId = node.paneId else { return nil }
            if let num = Int(paneId.split(separator: "p").last ?? ""), num >= ws.nextPaneNum {
                ws.nextPaneNum = num + 1
            }
            if node.kind == "web" {
                let url = node.url.flatMap { URL(string: $0) }
                webRuntimes[paneId] = WebPaneRuntime(id: paneId, url: url, model: self)
                return .pane(PaneLeaf(paneId: paneId, kind: "web"))
            }
            if node.kind == "world" {
                // the runtime is built lazily by worldRuntime(for:) on first render
                return .pane(PaneLeaf(paneId: paneId, kind: "world"))
            }
            var isDir: ObjCBool = false
            let cwd = (node.cwd != nil
                       && FileManager.default.fileExists(atPath: node.cwd!, isDirectory: &isDir)
                       && isDir.boolValue) ? node.cwd! : ws.cwd
            let rt = PaneRuntime(id: paneId, cwd: cwd, model: self)
            rt.label = node.label
            runtimes[paneId] = rt
            return .pane(PaneLeaf(paneId: paneId))
        }
        let a = restoreNode(node.a, ws: &ws)
        let b = restoreNode(node.b, ws: &ws)
        switch (a, b) {
        case (let x?, let y?): return .split(dir: node.dir ?? "row", ratio: node.ratio ?? 0.5, a: x, b: y)
        case (let x?, nil): return x
        case (nil, let y?): return y
        default: return nil
        }
    }

    // MARK: close-with-confirm helpers

    func requestClosePane(_ paneId: String) {
        let confirm = UserDefaults.standard.object(forKey: "confirmClose") as? Bool ?? true
        if confirm, let agent = runtimes[paneId]?.agent {
            activeSheet = .confirmClosePane(paneId: paneId, agent: agent)
        } else {
            closePane(paneId)
        }
    }

    func requestCloseTab(_ tab: TabState) {
        let confirm = UserDefaults.standard.object(forKey: "confirmClose") as? Bool ?? true
        if confirm, (tab.layout?.paneIds.count ?? 0) > 1 {
            activeSheet = .confirmCloseTab(tab)
        } else {
            closeTab(tab.id)
        }
    }

    func requestCloseSpace(_ ws: WorkspaceState) {
        let confirm = UserDefaults.standard.object(forKey: "confirmClose") as? Bool ?? true
        if confirm {
            activeSheet = .confirmCloseSpace(ws)
        } else {
            closeWorkspace(ws.id)
        }
    }
}

// MARK: - helpers

struct PSEntry {
    let pid: pid_t
    let kind: String?
    let base: String
}

func processTable() -> [pid_t: [PSEntry]] {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/ps")
    proc.arguments = ["-axo", "pid=,ppid=,args="]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    var children: [pid_t: [PSEntry]] = [:]
    do {
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return children }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]) else { continue }
            func clean(_ s: Substring) -> String {
                var b = (String(s) as NSString).lastPathComponent
                while b.hasPrefix("-") || b.hasPrefix("(") { b.removeFirst() }
                while b.hasSuffix(")") { b.removeLast() }
                return b
            }
            let b0 = clean(parts[2])
            let b1 = parts.count > 3 ? clean(parts[3]) : ""
            let kind = Agents.processMap[b0] ?? Agents.processMap[b1]
                ?? Agents.markerKind(line)
            children[ppid, default: []].append(PSEntry(pid: pid, kind: kind, base: b0))
        }
    } catch {}
    return children
}

/// Working directories for many shells in a single lsof call. Background only.
func lsofCwds(_ pids: [pid_t]) -> [pid_t: String] {
    guard !pids.isEmpty else { return [:] }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    proc.arguments = ["-a", "-p", pids.map(String.init).joined(separator: ","), "-d", "cwd", "-Fpn"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    guard (try? proc.run()) != nil else { return [:] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8) else { return [:] }
    var out: [pid_t: String] = [:]
    var current: pid_t?
    for line in text.split(separator: "\n") {
        if line.hasPrefix("p") { current = pid_t(line.dropFirst()) }
        else if line.hasPrefix("n"), let pid = current { out[pid] = String(line.dropFirst()) }
    }
    return out
}

func runGit(_ args: [String], completion: @escaping (Bool, String) -> Void) {
    DispatchQueue.global(qos: .utility).async {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let text = proc.terminationStatus == 0
                ? String(data: stdout, encoding: .utf8) ?? ""
                : String(data: stderr, encoding: .utf8) ?? ""
            completion(proc.terminationStatus == 0, text)
        } catch {
            completion(false, String(describing: error))
        }
    }
}
