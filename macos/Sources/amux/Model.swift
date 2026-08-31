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

struct PaneLeaf: Codable, Equatable, Identifiable {
    var paneId: String
    var kind: String        // "term" | "web" | "world"
    var label: String?
    var proc: String?
    var agent: PaneAgent?
    var cwd: String?        // shown in the pane header
    var branch: String?     // git branch for that cwd, when it is a repo

    var id: String { paneId }

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

/// A pane in the layout is a tab container, the way cmux arranges things: the
/// split tree holds groups, and each group shows one of its tabs at a time.
/// Tabs keep their paneId as identity, so every runtime registry stays keyed by
/// pane exactly as before.
struct PaneGroup: Codable, Equatable, Identifiable {
    var groupId: String
    var tabs: [PaneLeaf]
    var focusedPaneId: String

    var id: String { groupId }
    var focused: PaneLeaf? { tabs.first { $0.paneId == focusedPaneId } ?? tabs.first }

    init(groupId: String, tabs: [PaneLeaf], focusedPaneId: String? = nil) {
        self.groupId = groupId
        self.tabs = tabs
        self.focusedPaneId = focusedPaneId ?? tabs.first?.paneId ?? ""
    }
}

indirect enum LayoutNode: Equatable {
    case group(PaneGroup)
    case split(dir: String, ratio: Double, a: LayoutNode, b: LayoutNode)

    /// Every pane in every tab of every group, not just the visible ones.
    var paneIds: [String] {
        switch self {
        case .group(let g): return g.tabs.map(\.paneId)
        case .split(_, _, let a, let b): return a.paneIds + b.paneIds
        }
    }

    var groupIds: [String] {
        switch self {
        case .group(let g): return [g.groupId]
        case .split(_, _, let a, let b): return a.groupIds + b.groupIds
        }
    }

    var groups: [PaneGroup] {
        switch self {
        case .group(let g): return [g]
        case .split(_, _, let a, let b): return a.groups + b.groups
        }
    }

    /// The visible tab of each group: what is actually on screen.
    var visiblePaneIds: [String] {
        groups.compactMap { $0.focused?.paneId }
    }

    func leaf(for paneId: String) -> PaneLeaf? {
        switch self {
        case .group(let g): return g.tabs.first { $0.paneId == paneId }
        case .split(_, _, let a, let b): return a.leaf(for: paneId) ?? b.leaf(for: paneId)
        }
    }

    func group(id: String) -> PaneGroup? {
        switch self {
        case .group(let g): return g.groupId == id ? g : nil
        case .split(_, _, let a, let b): return a.group(id: id) ?? b.group(id: id)
        }
    }

    func groupContaining(paneId: String) -> PaneGroup? {
        switch self {
        case .group(let g): return g.tabs.contains { $0.paneId == paneId } ? g : nil
        case .split(_, _, let a, let b):
            return a.groupContaining(paneId: paneId) ?? b.groupContaining(paneId: paneId)
        }
    }

    /// Replace the group with `groupId` using `transform`; nil removes it
    /// (collapsing the parent split).
    func rewriting(groupId: String, _ transform: (LayoutNode) -> LayoutNode?) -> LayoutNode? {
        switch self {
        case .group(let g):
            return g.groupId == groupId ? transform(self) : self
        case .split(let dir, let ratio, let a, let b):
            let na = a.rewriting(groupId: groupId, transform)
            let nb = b.rewriting(groupId: groupId, transform)
            switch (na, nb) {
            case (nil, nil): return nil
            case (let x?, nil): return x
            case (nil, let y?): return y
            case (let x?, let y?): return .split(dir: dir, ratio: ratio, a: x, b: y)
            }
        }
    }

    /// Rewrite the group in place, keeping it a group. Returns nil when the
    /// transform empties it of tabs, which collapses the split.
    func mappingGroup(id: String, _ transform: (PaneGroup) -> PaneGroup?) -> LayoutNode? {
        rewriting(groupId: id) { node in
            guard case .group(let g) = node else { return node }
            guard let next = transform(g), !next.tabs.isEmpty else { return nil }
            return .group(next)
        }
    }

    /// Rewrite every group, for decoration passes.
    func mappingAllGroups(_ transform: (PaneGroup) -> PaneGroup) -> LayoutNode {
        switch self {
        case .group(let g): return .group(transform(g))
        case .split(let dir, let ratio, let a, let b):
            return .split(dir: dir, ratio: ratio,
                          a: a.mappingAllGroups(transform), b: b.mappingAllGroups(transform))
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
    var layout: LayoutNode?
    var focusedGroupId: String?
    var zoomedGroupId: String?
    var nextTabNum = 1
    var nextPaneNum = 1
    var nextGroupNum = 1

    var focusedGroup: PaneGroup? {
        guard let layout else { return nil }
        return focusedGroupId.flatMap { layout.group(id: $0) } ?? layout.groups.first
    }
    var focusedPaneId: String? { focusedGroup?.focusedPaneId }

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
    case confirmCloseGroup(PaneGroup)
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
        case .confirmCloseGroup(let g): return "closeGroup-\(g.groupId)"
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

    // Normalised activity, read from what the agents record about themselves.
    // See AgentSources.swift.
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
    /// Strip drops are a separate target from pane drops: a strip sits inside
    /// its pane's frame, so it has to be tested first and win.
    var stripFrames: [String: CGRect] = [:]     // groupId -> strip rect
    var chipFrames: [String: CGRect] = [:]      // paneId  -> tab chip rect
    @Published var trackedDropGroup: String?
    @Published var trackedDropIndex: Int?
    private var dropTracker: Timer?
    private var dragWatch: Timer?

    /// Called from every onDrag: while a drag is in flight, web panes float an
    /// invisible drop-catcher so WKWebView can't claim the session.
    private weak var dragSourceWindow: NSWindow?
    private var dragKeyMonitor: Any?

    func beginDrag(_ payload: String) {
        currentDragPayload = payload
        dragSourceWindow = NSApp.keyWindow
        dragActive = true
        // Escape cancels: without this, AppKit snaps the drag image back but
        // our pointer tracker still applies the move on mouse-up.
        dragKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.endDrag()
                return nil
            }
            return event
        }
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
        if let dragKeyMonitor { NSEvent.removeMonitor(dragKeyMonitor); self.dragKeyMonitor = nil }
        dragWatch?.invalidate()
        dragWatch = nil
        dropTracker?.invalidate()
        dropTracker = nil
        dragActive = false
        trackedDropPane = nil
        trackedDropEdge = nil
        trackedDropGroup = nil
        trackedDropIndex = nil
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
        // The drag started with a mouse-down in the pane window, so the window
        // captured at beginDrag is the right coordinate space. Falling back to
        // "first visible window" picked the About window when it was open.
        guard let win = dragSourceWindow
                ?? NSApp.keyWindow
                ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let content = win.contentView else { return nil }
        let p = win.convertPoint(fromScreen: NSEvent.mouseLocation)
        return CGPoint(x: p.x, y: content.bounds.height - p.y)
    }

    /// Which edge of a pane the pointer is nearest, measured in points.
    ///
    /// This used to compare fractions of the pane's width and height, which is
    /// wrong whenever a pane is not roughly square: in a 1245x211 browser pane
    /// every horizontal fraction is tiny, so "left" beat "down" along almost the
    /// whole bottom of the pane and a vertical split was unreachable except dead
    /// centre. Distances are the thing the eye is judging, so compare those.
    /// The middle 40% x 40% is still centre, so joining a pane's tabs by
    /// dropping on its body stays easy to hit.
    private func edgeFor(_ point: CGPoint, in frame: CGRect) -> String {
        let dl = point.x - frame.minX, dr = frame.maxX - point.x
        let dt = point.y - frame.minY, db = frame.maxY - point.y
        let padX = frame.width * 0.3, padY = frame.height * 0.3
        if dl > padX && dr > padX && dt > padY && db > padY { return "center" }
        let candidates: [(String, CGFloat)] = [
            ("left", dl), ("right", dr), ("up", dt), ("down", db),
        ]
        return candidates.min { $0.1 < $1.1 }!.0
    }

    /// Drop targets are the panes actually on screen: the visible tab of each
    /// group, or just the zoomed group when one is zoomed.
    /// Which tab strip the pointer is over, and where in its run of chips the
    /// dragged tab would land.
    private func strip(at point: CGPoint) -> (String, Int)? {
        guard let ws = focusedWorkspace, let layout = ws.layout else { return nil }
        let visible: [PaneGroup]
        if let z = ws.zoomedGroupId, let g = layout.group(id: z) { visible = [g] }
        else { visible = layout.groups }
        for g in visible {
            guard let f = stripFrames[g.groupId], f.contains(point) else { continue }
            // insert before the first chip whose midpoint is right of the pointer
            var index = g.tabs.count
            for (i, leaf) in g.tabs.enumerated() {
                guard let c = chipFrames[leaf.paneId] else { continue }
                if point.x < c.midX { index = i; break }
            }
            return (g.groupId, index)
        }
        return nil
    }

    private func pane(at point: CGPoint) -> (String, CGRect)? {
        guard let ws = focusedWorkspace, let layout = ws.layout else { return nil }
        let candidates: [String]
        if let z = ws.zoomedGroupId, let g = layout.group(id: z) {
            candidates = [g.focusedPaneId]
        } else {
            candidates = layout.visiblePaneIds
        }
        for paneId in candidates {
            guard let f = paneFrames[paneId], f.contains(point) else { continue }
            // Edges belong to the pane's content. Measuring them over the whole
            // pane counted the tab strip as part of the top edge, which pushed
            // the "up" band down out of reach in a short pane.
            guard let g = layout.groupContaining(paneId: paneId),
                  let strip = stripFrames[g.groupId], strip.maxY > f.minY else { return (paneId, f) }
            return (paneId, CGRect(x: f.minX, y: strip.maxY,
                                   width: f.width, height: max(f.maxY - strip.maxY, 1)))
        }
        return nil
    }

    private func updateTrackedDrop() {
        guard dragActive, let p = pointerInWindow() else { return }
        // Short and lightly damped: the highlight should chase the pointer
        // between edges without feeling loose.
        let motion = SwiftUI.Animation.spring(response: 0.17, dampingFraction: 0.82)
        if let (groupId, index) = strip(at: p) {
            if trackedDropGroup != groupId || trackedDropIndex != index || trackedDropPane != nil {
                withAnimation(motion) {
                    trackedDropGroup = groupId
                    trackedDropIndex = index
                    trackedDropPane = nil
                    trackedDropEdge = nil
                }
            }
        } else if let (paneId, frame) = pane(at: p) {
            let e = edgeFor(p, in: frame)
            if trackedDropPane != paneId || trackedDropEdge != e || trackedDropGroup != nil {
                withAnimation(motion) {
                    trackedDropPane = paneId
                    trackedDropEdge = e
                    trackedDropGroup = nil
                    trackedDropIndex = nil
                }
            }
        } else if trackedDropPane != nil || trackedDropGroup != nil {
            withAnimation(motion) {
                trackedDropPane = nil
                trackedDropEdge = nil
                trackedDropGroup = nil
                trackedDropIndex = nil
            }
        }
    }

    private func finishTrackedDrop() {
        let target = trackedDropPane
        let edge = trackedDropEdge
        let stripGroup = trackedDropGroup
        let stripIndex = trackedDropIndex
        let payload = currentDragPayload
        dropTracker?.invalidate()
        dropTracker = nil
        dragActive = false
        trackedDropPane = nil
        trackedDropEdge = nil
        trackedDropGroup = nil
        trackedDropIndex = nil
        currentDragPayload = nil
        guard let payload else { return }
        let settleStrip = SwiftUI.Animation.spring(response: 0.28, dampingFraction: 0.86)
        // dropped on a tab strip: join that pane's tabs at the insertion point
        if let stripGroup {
            let src = String(payload.dropFirst(payload.hasPrefix("tab:") ? 4 : 5))
            withAnimation(settleStrip) {
                if let (_, g) = locateGroup(src), g == stripGroup {
                    moveTab(src, toIndex: stripIndex ?? 0)
                } else {
                    moveTab(src, toGroup: stripGroup, atIndex: stripIndex)
                }
            }
            return
        }
        guard let target, let edge else { return }
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
            let src = String(payload.dropFirst(4))
            // Dropping a tab on its own pane's edge splits that pane and takes
            // the tab with it, which is only meaningful if a tab is left behind.
            if src == target,
               (locateGroup(src).flatMap { focusedWorkspace?.layout?.group(id: $0.1)?.tabs.count } ?? 1) < 2 {
                return
            }
            withAnimation(settle) {
                if edge == "center" { movePane(src, intoGroupOf: target) }
                else { movePane(src, toEdge: edge, of: target) }
            }
        }
    }

    /// Pane commands should still work when nothing has been clicked yet.
    var actionPaneId: String? {
        focusedWorkspace?.focusedPaneId ?? focusedWorkspace?.layout?.visiblePaneIds.first
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

    static let version = "0.3.0"

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
            for ws in workspaces where ws.layout?.leaf(for: paneId) != nil {
                if ws.layout?.groupContaining(paneId: paneId)?.focusedPaneId != paneId
                    || focusedWorkspaceId != ws.id {
                    focus(workspaceId: ws.id, paneId: paneId)
                }
                return
            }
            return
        }
        for (paneId, rt) in runtimes {
            guard hit === rt.view || hit.isDescendant(of: rt.view) else { continue }
            if window.firstResponder !== rt.view {
                window.makeFirstResponder(rt.view)
            }
            for ws in workspaces where ws.layout?.leaf(for: paneId) != nil {
                if ws.layout?.groupContaining(paneId: paneId)?.focusedPaneId != paneId
                    || focusedWorkspaceId != ws.id {
                    focus(workspaceId: ws.id, paneId: paneId)
                }
                return
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
            if let layout = workspaces[wi].layout {
                workspaces[wi].layout = decorate(layout)
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
        node.mappingAllGroups { g in
            var g = g
            g.tabs = g.tabs.map { leaf in
                var leaf = leaf
                if leaf.kind == "web" {
                    if let wrt = webRuntimes[leaf.paneId] {
                        leaf.label = wrt.title
                        leaf.proc = "web"
                    }
                } else if leaf.kind == "world" {
                    leaf.label = leaf.label ?? "agent world"
                } else if let rt = runtimes[leaf.paneId] {
                    leaf.label = rt.label
                    leaf.proc = rt.procName
                    leaf.agent = rt.agent
                    leaf.cwd = rt.cachedCwd
                    leaf.branch = rt.cachedCwd.flatMap { branchByDir[$0] }
                }
                return leaf
            }
            return g
        }
    }

    private func agentRows() -> [AgentRow] {
        var rows: [AgentRow] = []
        for ws in workspaces {
            for g in ws.layout?.groups ?? [] {
                for leaf in g.tabs {
                    guard let rt = runtimes[leaf.paneId], let agent = rt.agent else { continue }
                    rows.append(AgentRow(
                        paneId: leaf.paneId, wsId: ws.id, tabId: g.groupId,
                        workspace: ws.label,
                        tab: leaf.label ?? agent.name ?? agent.kind,
                        kind: agent.kind, name: agent.name, state: agent.state))
                }
            }
        }
        return rows
    }

    // MARK: derived

    var focusedWorkspace: WorkspaceState? {
        workspaces.first { $0.id == focusedWorkspaceId }
    }

    var focusedGroup: PaneGroup? { focusedWorkspace?.focusedGroup }

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

    /// Cycles fake agents through every behaviour in every open world pane, so
    /// the visualisation can be seen without standing up five real agents.
    func toggleWorldDemo() {
        let on = !(worldRuntimes.values.first?.demoMode ?? false)
        for rt in worldRuntimes.values { rt.demoMode = on }
    }

    /// Opens the agent world as a tab in the focused pane.
    func newWorldTab() {
        guard let ws = focusedWorkspace, let wi = wsIndex(ws.id) else { return }
        var w = workspaces[wi]
        let paneId = "\(w.id):p\(w.nextPaneNum)"
        w.nextPaneNum += 1
        let leaf = PaneLeaf(paneId: paneId, kind: "world")
        if let layout = w.layout, let target = w.focusedGroup {
            w.layout = layout.mappingGroup(id: target.groupId) { g in
                var g = g; g.tabs.append(leaf); g.focusedPaneId = paneId; return g
            }
            w.focusedGroupId = target.groupId
        } else {
            let g = PaneGroup(groupId: "\(w.id):g\(w.nextGroupNum)", tabs: [leaf])
            w.nextGroupNum += 1
            w.layout = .group(g)
            w.focusedGroupId = g.groupId
        }
        workspaces[wi] = w
        focusedWorkspaceId = w.id
        publish()
    }

    /// A browser opens as a tab in the focused pane, like any other tab.
    func newBrowserTab(url: URL? = nil) {
        guard let ws = focusedWorkspace else { return }
        _ = newTab(ws, kind: "web", url: url)
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
            cwd: dir, git: nil, worktreeInfo: nil, icon: nil, layout: nil)
        nextWorkspaceNum += 1
        let paneId = makePane(ws: &ws, cwd: dir)
        let g = PaneGroup(groupId: "\(ws.id):g\(ws.nextGroupNum)",
                          tabs: [PaneLeaf(paneId: paneId)])
        ws.nextGroupNum += 1
        ws.layout = .group(g)
        ws.focusedGroupId = g.groupId
        workspaces.append(ws)
        focusedWorkspaceId = ws.id
        publish()
        gitTick()
    }

    /// A new tab joins the focused group, the way a browser tab joins a window.
    /// With no groups yet (a fresh space) it creates the first one.
    @discardableResult
    func newTab(_ wsIn: WorkspaceState, kind: String = "term", url: URL? = nil) -> String? {
        guard let wi = wsIndex(wsIn.id) else { return nil }
        var ws = workspaces[wi]
        let paneId = kind == "web" ? makeWebPane(ws: &ws, url: url) : makePane(ws: &ws, cwd: ws.cwd)
        let leaf = PaneLeaf(paneId: paneId, kind: kind)
        if let layout = ws.layout, let target = ws.focusedGroup {
            ws.layout = layout.mappingGroup(id: target.groupId) { g in
                var g = g
                g.tabs.append(leaf)
                g.focusedPaneId = paneId
                return g
            }
            ws.focusedGroupId = target.groupId
        } else {
            let g = PaneGroup(groupId: "\(ws.id):g\(ws.nextGroupNum)", tabs: [leaf])
            ws.nextGroupNum += 1
            ws.layout = .group(g)
            ws.focusedGroupId = g.groupId
        }
        workspaces[wi] = ws
        publish()
        return paneId
    }

    /// Splitting makes a new group beside the one holding `paneId`, with one
    /// fresh tab in it.
    @discardableResult
    func splitPane(_ paneId: String, direction: String, kind: String = "term") -> String? {
        guard let wi = wsIndex(workspaceIdContaining(paneId)),
              let layout = workspaces[wi].layout,
              let source = layout.groupContaining(paneId: paneId) else { return nil }
        var ws = workspaces[wi]
        let cwd = runtimes[paneId]?.currentCwd() ?? ws.cwd
        let newId = kind == "web" ? makeWebPane(ws: &ws, url: nil) : makePane(ws: &ws, cwd: cwd)
        let g = PaneGroup(groupId: "\(ws.id):g\(ws.nextGroupNum)",
                          tabs: [PaneLeaf(paneId: newId, kind: kind)])
        ws.nextGroupNum += 1
        let dir = direction == "down" ? "column" : "row"
        ws.layout = ws.layout?.rewriting(groupId: source.groupId) { old in
            .split(dir: dir, ratio: 0.5, a: old, b: .group(g))
        }
        ws.focusedGroupId = g.groupId
        ws.zoomedGroupId = nil
        workspaces[wi] = ws
        publish()
        return newId
    }

    @discardableResult
    func splitPaneWithBrowser(_ paneId: String, direction: String) -> String? {
        splitPane(paneId, direction: direction, kind: "web")
    }

    private func workspaceIdContaining(_ paneId: String) -> String? {
        workspaces.first { $0.layout?.leaf(for: paneId) != nil }?.id
    }

    /// The workspace index and group id holding a pane, in any tab of any group.
    private func locate(_ paneId: String) -> (Int, String)? {
        for wi in workspaces.indices {
            if let g = workspaces[wi].layout?.groupContaining(paneId: paneId) {
                return (wi, g.groupId)
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

    /// Removes one tab. An emptied group collapses out of the split tree, and
    /// an emptied workspace closes, matching what closing the last tab of a
    /// window does elsewhere.
    private func removePaneFromLayout(_ paneId: String) {
        guard let (wi, groupId) = locate(paneId) else { return }
        var ws = workspaces[wi]
        ws.layout = ws.layout?.mappingGroup(id: groupId) { g in
            var g = g
            guard let idx = g.tabs.firstIndex(where: { $0.paneId == paneId }) else { return g }
            g.tabs.remove(at: idx)
            if g.focusedPaneId == paneId {
                g.focusedPaneId = g.tabs[max(0, idx - 1)...].first?.paneId ?? g.tabs.first?.paneId ?? ""
            }
            return g
        }
        if let layout = ws.layout {
            if ws.focusedGroupId == nil || layout.group(id: ws.focusedGroupId!) == nil {
                ws.focusedGroupId = layout.groupIds.first
            }
            if let z = ws.zoomedGroupId, layout.group(id: z) == nil { ws.zoomedGroupId = nil }
            workspaces[wi] = ws
        } else {
            workspaces[wi] = ws
            if workspaces.count > 1 { closeWorkspaceRecord(ws.id) }
        }
    }

    /// Closes one tab of a group. Kept distinct from closePane so the menu and
    /// the tab chip's x can share it.
    func closeTab(_ paneId: String) { closePane(paneId) }

    /// Closes an entire group and everything in it.
    func closeGroup(_ groupId: String) {
        guard let wi = workspaces.firstIndex(where: { $0.layout?.group(id: groupId) != nil }),
              let g = workspaces[wi].layout?.group(id: groupId) else { return }
        for leaf in g.tabs { discardRuntimes(leaf.paneId) }
        var ws = workspaces[wi]
        ws.layout = ws.layout?.rewriting(groupId: groupId) { _ in nil }
        if let layout = ws.layout {
            if ws.focusedGroupId == groupId { ws.focusedGroupId = layout.groupIds.first }
            if ws.zoomedGroupId == groupId { ws.zoomedGroupId = nil }
            workspaces[wi] = ws
        } else {
            workspaces[wi] = ws
            if workspaces.count > 1 { closeWorkspaceRecord(ws.id) }
        }
        publish()
    }

    private func discardRuntimes(_ paneId: String) {
        runtimes[paneId]?.terminate()
        runtimes.removeValue(forKey: paneId)
        webRuntimes[paneId]?.detach()
        webRuntimes.removeValue(forKey: paneId)
        worldRuntimes.removeValue(forKey: paneId)
        claudeReaders.removeValue(forKey: paneId)
        codexReaders.removeValue(forKey: paneId)
        paneFrames.removeValue(forKey: paneId)
    }

    private func closeWorkspaceRecord(_ wsId: String) {
        workspaces.removeAll { $0.id == wsId }
        if focusedWorkspaceId == wsId { focusedWorkspaceId = workspaces.first?.id }
    }

    func closeWorkspace(_ wsId: String, removeWorktree: Bool = false) {
        guard let wi = wsIndex(wsId) else { return }
        let ws = workspaces[wi]
        for pid in ws.layout?.paneIds ?? [] { discardRuntimes(pid) }
        closeWorkspaceRecord(wsId)
        if removeWorktree, let wt = ws.worktreeInfo {
            runGit(["-C", wt.parentRepo, "worktree", "remove", "--force", wt.path]) { _, _ in }
        }
        publish()
    }

    /// Focusing a pane also selects it within its group and focuses that group,
    /// so callers only ever have to name the pane they care about.
    func focus(workspaceId: String? = nil, paneId: String? = nil) {
        if let workspaceId, wsIndex(workspaceId) != nil { focusedWorkspaceId = workspaceId }
        guard let wi = wsIndex(focusedWorkspaceId) else { publish(); return }
        var ws = workspaces[wi]
        if let paneId, let g = ws.layout?.groupContaining(paneId: paneId) {
            ws.layout = ws.layout?.mappingGroup(id: g.groupId) { grp in
                var grp = grp
                grp.focusedPaneId = paneId
                return grp
            }
            ws.focusedGroupId = g.groupId
        }
        workspaces[wi] = ws
        if let paneId { markPaneSeen(paneId) }
        publish()
    }

    func focusGroup(_ groupId: String) {
        guard let wi = wsIndex(focusedWorkspaceId),
              let g = workspaces[wi].layout?.group(id: groupId) else { return }
        workspaces[wi].focusedGroupId = groupId
        markPaneSeen(g.focusedPaneId)
        publish()
    }

    private func followFocus() {
        let focused = focusedWorkspace?.focusedPaneId
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

    /// A tab is a pane now, so renaming either means the same thing.
    func renameTab(_ paneId: String, label: String) { renamePane(paneId, label: label) }

    func renamePane(_ id: String, label: String) {
        runtimes[id]?.label = label.isEmpty ? nil : label
        publish()
    }

    func setSpaceIcon(_ wsId: String, icon: String?) {
        guard let wi = wsIndex(wsId) else { return }
        workspaces[wi].icon = (icon?.isEmpty ?? true) ? nil : icon
        publish()
    }

    func setRatio(workspaceId: String, path: String, ratio: Double) {
        guard let wi = wsIndex(workspaceId) else { return }
        workspaces[wi].layout =
            workspaces[wi].layout?.updatingRatio(path: path, ratio: min(0.9, max(0.1, ratio)))
        publish()
    }

    /// Zoom hides the other groups, not the other tabs: a zoomed pane still
    /// shows its own tab strip so you can switch inside it.
    func zoomPane(_ paneId: String) {
        guard let (wi, groupId) = locate(paneId) else { return }
        workspaces[wi].zoomedGroupId = workspaces[wi].zoomedGroupId == groupId ? nil : groupId
        publish()
    }

    // MARK: moves / swaps / merges

    /// Dropping a tab on another pane's edge pulls it out into a new group
    /// beside that one.
    func movePane(_ paneId: String, toEdge edge: String, of targetPaneId: String) {
        guard paneId != targetPaneId, let (swi, _) = locate(paneId),
              let leaf = workspaces[swi].layout?.leaf(for: paneId),
              let (twi, targetGroupId) = locate(targetPaneId), twi == swi else { return }
        var ws = workspaces[swi]
        detachLeaf(paneId, in: &ws)
        // the source group may have collapsed under the detach
        guard ws.layout?.group(id: targetGroupId) != nil else {
            workspaces[swi] = ws; publish(); return
        }
        let g = PaneGroup(groupId: "\(ws.id):g\(ws.nextGroupNum)", tabs: [leaf])
        ws.nextGroupNum += 1
        let dir = (edge == "left" || edge == "right") ? "row" : "column"
        let movedFirst = (edge == "left" || edge == "up")
        ws.layout = ws.layout?.rewriting(groupId: targetGroupId) { old in
            .split(dir: dir, ratio: 0.5,
                   a: movedFirst ? .group(g) : old,
                   b: movedFirst ? old : .group(g))
        }
        ws.focusedGroupId = g.groupId
        ws.zoomedGroupId = nil
        workspaces[swi] = ws
        publish()
    }

    /// Dropping a tab on another pane's middle moves it into that pane's strip.
    func movePane(_ paneId: String, intoGroupOf targetPaneId: String) {
        guard let (_, targetGroupId) = locate(targetPaneId) else { return }
        moveTab(paneId, toGroup: targetGroupId)
    }

    func movePane(_ paneId: String, toWorkspace wsId: String) {
        guard let (swi, _) = locate(paneId),
              let leaf = workspaces[swi].layout?.leaf(for: paneId),
              let target = wsIndex(wsId), target != swi else { return }
        var source = workspaces[swi]
        detachLeaf(paneId, in: &source)
        workspaces[swi] = source
        guard let ti = wsIndex(wsId) else { publish(); return }
        var ws = workspaces[ti]
        if let layout = ws.layout, let focused = ws.focusedGroup {
            ws.layout = layout.mappingGroup(id: focused.groupId) { g in
                var g = g
                g.tabs.append(leaf)
                g.focusedPaneId = leaf.paneId
                return g
            }
            ws.focusedGroupId = focused.groupId
        } else {
            let g = PaneGroup(groupId: "\(ws.id):g\(ws.nextGroupNum)", tabs: [leaf])
            ws.nextGroupNum += 1
            ws.layout = .group(g)
            ws.focusedGroupId = g.groupId
        }
        workspaces[ti] = ws
        focusedWorkspaceId = wsId
        publish()
    }

    /// Removes a tab's leaf from a workspace without killing its runtime.
    private func detachLeaf(_ paneId: String, in ws: inout WorkspaceState) {
        guard let g = ws.layout?.groupContaining(paneId: paneId) else { return }
        ws.layout = ws.layout?.mappingGroup(id: g.groupId) { grp in
            var grp = grp
            grp.tabs.removeAll { $0.paneId == paneId }
            if grp.focusedPaneId == paneId { grp.focusedPaneId = grp.tabs.first?.paneId ?? "" }
            return grp
        }
        if let layout = ws.layout {
            if ws.focusedGroupId == nil || layout.group(id: ws.focusedGroupId!) == nil {
                ws.focusedGroupId = layout.groupIds.first
            }
            if let z = ws.zoomedGroupId, layout.group(id: z) == nil { ws.zoomedGroupId = nil }
        }
    }

    /// Swaps the two groups holding these panes, in one traversal: rewriting
    /// twice duplicates one and orphans the other.
    func swapPanes(_ a: String, _ b: String) {
        guard let (wi, ga) = locate(a), let (wj, gb) = locate(b), wi == wj, ga != gb,
              let layout = workspaces[wi].layout,
              let groupA = layout.group(id: ga), let groupB = layout.group(id: gb) else { return }
        func exchange(_ node: LayoutNode) -> LayoutNode {
            switch node {
            case .group(let g):
                if g.groupId == ga { return .group(groupB) }
                if g.groupId == gb { return .group(groupA) }
                return node
            case .split(let dir, let ratio, let x, let y):
                return .split(dir: dir, ratio: ratio, a: exchange(x), b: exchange(y))
            }
        }
        workspaces[wi].layout = exchange(layout)
        publish()
    }

    /// Whether two panes live in the same group, which decides between a
    /// reorder and a move when a tab chip is dropped on another.
    /// The workspace index and group id holding a pane, exposed for the drop
    /// tracker's strip handling.
    func locateGroup(_ paneId: String) -> (Int, String)? { locate(paneId) }

    func sameGroup(_ a: String, _ b: String) -> Bool {
        guard let (_, ga) = locate(a), let (_, gb) = locate(b) else { return false }
        return ga == gb
    }

    /// Reorders a tab inside its own group.
    func moveTab(_ paneId: String, toIndex: Int) {
        guard let (wi, groupId) = locate(paneId) else { return }
        workspaces[wi].layout = workspaces[wi].layout?.mappingGroup(id: groupId) { g in
            var g = g
            guard let from = g.tabs.firstIndex(where: { $0.paneId == paneId }) else { return g }
            let leaf = g.tabs.remove(at: from)
            g.tabs.insert(leaf, at: max(0, min(g.tabs.count, toIndex)))
            return g
        }
        publish()
    }

    /// Moves a tab into another group, which is what dropping a tab chip onto
    /// a different pane's strip does.
    func moveTab(_ paneId: String, toGroup targetGroupId: String, atIndex: Int? = nil) {
        guard let (wi, sourceGroupId) = locate(paneId), sourceGroupId != targetGroupId,
              let leaf = workspaces[wi].layout?.leaf(for: paneId),
              workspaces[wi].layout?.group(id: targetGroupId) != nil else { return }
        var ws = workspaces[wi]
        ws.layout = ws.layout?.mappingGroup(id: sourceGroupId) { g in
            var g = g
            g.tabs.removeAll { $0.paneId == paneId }
            if g.focusedPaneId == paneId { g.focusedPaneId = g.tabs.first?.paneId ?? "" }
            return g
        }
        // the source group may have collapsed, so re-check the target still exists
        guard ws.layout?.group(id: targetGroupId) != nil else { workspaces[wi] = ws; publish(); return }
        ws.layout = ws.layout?.mappingGroup(id: targetGroupId) { g in
            var g = g
            let at = atIndex.map { max(0, min(g.tabs.count, $0)) } ?? g.tabs.count
            g.tabs.insert(leaf, at: at)
            g.focusedPaneId = paneId
            return g
        }
        ws.focusedGroupId = targetGroupId
        ws.zoomedGroupId = nil
        workspaces[wi] = ws
        publish()
    }

    // MARK: tab / space navigation

    func selectTab(index: Int) {
        guard let ws = focusedWorkspace, let g = ws.focusedGroup, index < g.tabs.count else { return }
        focus(workspaceId: ws.id, paneId: g.tabs[index].paneId)
    }

    func stepTab(_ delta: Int) {
        guard let ws = focusedWorkspace, let g = ws.focusedGroup, !g.tabs.isEmpty,
              let i = g.tabs.firstIndex(where: { $0.paneId == g.focusedPaneId }) else { return }
        let n = (i + delta + g.tabs.count) % g.tabs.count
        focus(workspaceId: ws.id, paneId: g.tabs[n].paneId)
    }

    func selectSpace(index: Int) {
        guard index < workspaces.count else { return }
        focus(workspaceId: workspaces[index].id)
    }

    func focusDirection(_ dir: String) {
        guard let ws = focusedWorkspace, let layout = ws.layout,
              let current = ws.focusedGroup?.groupId else { return }
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
        if let best { focusGroup(best.id) }
    }

    private func overlaps(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> Bool {
        a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }

    private func collectUnitRects(_ node: LayoutNode, _ rect: CGRect, _ out: inout [String: CGRect]) {
        switch node {
        case .group(let g):
            out[g.groupId] = rect
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

    /// Visible means: its workspace is focused and it is the tab its group is
    /// showing. A background tab of a visible group is not visible.
    private func isPaneVisibleFocused(_ paneId: String) -> Bool {
        guard let ws = focusedWorkspace,
              let g = ws.layout?.groupContaining(paneId: paneId) else { return false }
        return g.focusedPaneId == paneId
    }

    private func markPaneSeen(_ paneId: String) {
        if runtimes[paneId]?.agent?.state == "done" { runtimes[paneId]?.agent?.state = "idle" }
    }

    private func notifyAgent(paneId: String, rt: PaneRuntime, newState: String) {
        guard let (wi, ti) = locate(paneId) else { return }
        let item = NotificationItem(
            paneId: paneId, wsId: workspaces[wi].id, tabId: ti,
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
        focus(workspaceId: item.wsId, paneId: item.paneId)
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
        var type: String = "group"
        var groupId: String?
        var focusedPaneId: String?
        var tabs: [DumpNode]?
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
        var nextGroupNum: Int?
        /// Current format: the space owns one layout of groups.
        var layout: DumpNode?
        /// Old format, read for migration only and never written again.
        var tabs: [DumpTab]?
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
                       worktree: ws.worktreeInfo, focusedTabId: ws.focusedGroupId,
                       nextTabNum: ws.nextTabNum, nextPaneNum: ws.nextPaneNum,
                       nextGroupNum: ws.nextGroupNum,
                       layout: dumpNode(ws.layout), tabs: nil)
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
        case .group(let g):
            d.type = "group"
            d.groupId = g.groupId
            d.focusedPaneId = g.focusedPaneId
            d.tabs = g.tabs.map { leaf in
                let t = DumpNode()
                t.type = "pane"
                t.paneId = leaf.paneId
                t.kind = leaf.kind
                if leaf.kind == "web" {
                    t.url = webRuntimes[leaf.paneId]?.url?.absoluteString
                } else {
                    t.cwd = runtimes[leaf.paneId]?.currentCwd()
                    t.label = runtimes[leaf.paneId]?.label
                }
                return t
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
                worktreeInfo: dws.worktree, icon: dws.icon, layout: nil)
            ws.nextTabNum = dws.nextTabNum ?? 1
            ws.nextPaneNum = dws.nextPaneNum ?? 1
            ws.nextGroupNum = dws.nextGroupNum ?? 1

            if let layout = dws.layout {
                ws.layout = restoreNode(layout, ws: &ws)
                ws.focusedGroupId = ws.layout?.group(id: dws.focusedTabId ?? "")?.groupId
                    ?? ws.layout?.groupIds.first
            } else if let oldTabs = dws.tabs {
                ws.layout = migrateOldTabs(oldTabs, focused: dws.focusedTabId, ws: &ws)
                ws.focusedGroupId = ws.layout?.groupIds.first
            }
            guard ws.layout != nil else { continue }
            workspaces.append(ws)
        }
        focusedWorkspaceId = workspaces.contains { $0.id == dump.focusedWorkspaceId }
            ? dump.focusedWorkspaceId : workspaces.first?.id
        gitTick()
    }

    /// Migration from the format where a space owned the tabs and each tab
    /// owned a layout. The focused tab's splits become the space's layout, with
    /// every pane in it becoming a single-tab group; every pane from the other
    /// tabs is then appended as an extra tab on the first group. Nothing is
    /// dropped, so no pty is stranded, but arrangements from non-focused tabs
    /// cannot be preserved because a space only has one layout now.
    private func migrateOldTabs(_ tabs: [DumpTab], focused: String?,
                                ws: inout WorkspaceState) -> LayoutNode? {
        let ordered = tabs.sorted { a, _ in a.id == focused }
        var root: LayoutNode?
        var spare: [PaneLeaf] = []
        for (i, dtab) in ordered.enumerated() {
            guard let restored = restoreNode(dtab.layout, ws: &ws) else { continue }
            if i == 0 {
                root = groupsFromPanes(restored, ws: &ws)
            } else {
                spare.append(contentsOf: restored.groups.flatMap(\.tabs))
            }
        }
        guard var layout = root else {
            guard !spare.isEmpty else { return nil }
            let g = PaneGroup(groupId: "\(ws.id):g\(ws.nextGroupNum)", tabs: spare)
            ws.nextGroupNum += 1
            return .group(g)
        }
        if !spare.isEmpty, let first = layout.groupIds.first {
            layout = layout.mappingGroup(id: first) { g in
                var g = g; g.tabs.append(contentsOf: spare); return g
            } ?? layout
        }
        return layout
    }

    /// Wraps each restored single-pane group in its own group, preserving the
    /// split arrangement from the old format.
    private func groupsFromPanes(_ node: LayoutNode, ws: inout WorkspaceState) -> LayoutNode {
        node.mappingAllGroups { g in
            var g = g
            if g.groupId.isEmpty {
                g.groupId = "\(ws.id):g\(ws.nextGroupNum)"
                ws.nextGroupNum += 1
            }
            return g
        }
    }

    /// Restores both formats. "group" is current; a bare "pane" is the old
    /// format, and is wrapped in a single-tab group so migration can reuse this.
    private func restoreNode(_ node: DumpNode?, ws: inout WorkspaceState) -> LayoutNode? {
        guard let node else { return nil }

        func restoreLeaf(_ n: DumpNode) -> PaneLeaf? {
            guard let paneId = n.paneId else { return nil }
            if let num = Int(paneId.split(separator: "p").last ?? ""), num >= ws.nextPaneNum {
                ws.nextPaneNum = num + 1
            }
            if n.kind == "web" {
                webRuntimes[paneId] = WebPaneRuntime(
                    id: paneId, url: n.url.flatMap { URL(string: $0) }, model: self)
                return PaneLeaf(paneId: paneId, kind: "web")
            }
            if n.kind == "world" {
                // the runtime is built lazily by worldRuntime(for:) on first render
                return PaneLeaf(paneId: paneId, kind: "world")
            }
            var isDir: ObjCBool = false
            let cwd = (n.cwd != nil
                       && FileManager.default.fileExists(atPath: n.cwd!, isDirectory: &isDir)
                       && isDir.boolValue) ? n.cwd! : ws.cwd
            let rt = PaneRuntime(id: paneId, cwd: cwd, model: self)
            rt.label = n.label
            runtimes[paneId] = rt
            return PaneLeaf(paneId: paneId)
        }

        switch node.type {
        case "group":
            let leaves = (node.tabs ?? []).compactMap(restoreLeaf)
            guard !leaves.isEmpty else { return nil }
            let gid = node.groupId ?? "\(ws.id):g\(ws.nextGroupNum)"
            if node.groupId == nil { ws.nextGroupNum += 1 }
            if let num = Int(gid.split(separator: "g").last ?? ""), num >= ws.nextGroupNum {
                ws.nextGroupNum = num + 1
            }
            let focused = leaves.contains { $0.paneId == node.focusedPaneId }
                ? node.focusedPaneId : leaves.first?.paneId
            return .group(PaneGroup(groupId: gid, tabs: leaves, focusedPaneId: focused))
        case "pane":
            // old format: one pane became one group
            guard let leaf = restoreLeaf(node) else { return nil }
            let gid = "\(ws.id):g\(ws.nextGroupNum)"
            ws.nextGroupNum += 1
            return .group(PaneGroup(groupId: gid, tabs: [leaf]))
        default:
            let a = restoreNode(node.a, ws: &ws)
            let b = restoreNode(node.b, ws: &ws)
            switch (a, b) {
            case (let x?, let y?):
                return .split(dir: node.dir ?? "row", ratio: node.ratio ?? 0.5, a: x, b: y)
            case (let x?, nil): return x
            case (nil, let y?): return y
            default: return nil
            }
        }
    }

    func requestClosePane(_ paneId: String) {
        let confirm = UserDefaults.standard.object(forKey: "confirmClose") as? Bool ?? true
        if confirm, let agent = runtimes[paneId]?.agent {
            activeSheet = .confirmClosePane(paneId: paneId, agent: agent)
        } else {
            closePane(paneId)
        }
    }

    /// Closing a group with more than one tab asks first; closing a single tab
    /// does not, the same way a browser treats a window versus a tab.
    func requestCloseGroup(_ group: PaneGroup) {
        let confirm = UserDefaults.standard.object(forKey: "confirmClose") as? Bool ?? true
        if confirm, group.tabs.count > 1 {
            activeSheet = .confirmCloseGroup(group)
        } else {
            closeGroup(group.groupId)
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
