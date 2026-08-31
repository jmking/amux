import SwiftUI
import UniformTypeIdentifiers

// In-app drag payloads travel as a private type so WKWebView never claims the
// session (it eats plain-text drops, which broke snapping onto browser panes).
enum PaneDrag {
    static let typeID = "au.jmk.amux.panedrag"
    static let type = UTType(exportedAs: "au.jmk.amux.panedrag")

    static func provider(_ payload: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: typeID,
                                            visibility: .all) { completion in
            completion(payload.data(using: .utf8), nil)
            return nil
        }
        return provider
    }
}

// MARK: - Tab bar

struct TabBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.palette) private var pal
    @State private var showBell = false

    var body: some View {
        HStack(spacing: 4) {
            if !model.sidebarCollapsed {
                Button { withAnimation(.easeOut(duration: 0.15)) { model.sidebarCollapsed = true } } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 12))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(pal.faint)
                .help("Hide sidebar (⌘0)")
                .padding(.trailing, 2)
            }
            if let ws = model.focusedWorkspace {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(ws.tabs.enumerated()), id: \.element.id) { index, tab in
                                TabChip(model: model, ws: ws, tab: tab, index: index,
                                        active: tab.id == ws.focusedTabId)
                                    .id(tab.id)
                            }
                        }
                    }
                    .onChange(of: ws.focusedTabId) { _, focused in
                        // no animation: the strip should land the instant you click
                        if let focused { proxy.scrollTo(focused) }
                    }
                    .onAppear {
                        if let focused = ws.focusedTabId { proxy.scrollTo(focused) }
                    }
                }
            }
            Spacer()
            HStack(spacing: 10) {
                // Creating and splitting moved onto the pane headers, where cmux
                // keeps them: those actions are about a pane, so they belong on
                // the pane rather than in a bar that floats above all of them.
                clusterButton("magnifyingglass", "Command palette (⌘K)") { model.paletteOpen = true }
                bellButton
            }
            .font(.system(size: 11))
            .foregroundStyle(pal.faint2)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(pal.bg)
    }

    private func clusterButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(pal.faint)
        .help(help)
    }

    private var bellButton: some View {
        Button {
            model.unseenNotifications = 0
            showBell.toggle()
        } label: {
            Image(systemName: "bell")
                .font(.system(size: 11))
                .overlay(alignment: .topTrailing) {
                    if model.unseenNotifications > 0 {
                        Circle().fill(AgentStateColor.color("blocked"))
                            .frame(width: 6, height: 6).offset(x: 3, y: -2)
                    }
                }
        }
        .buttonStyle(.plain).foregroundStyle(pal.faint)
        .popover(isPresented: $showBell, arrowEdge: .bottom) {
            BellPopover(model: model, dismiss: { showBell = false })
        }
        .help("Notifications (⇧⌘O opens latest)")
    }
}

struct BellPopover: View {
    @ObservedObject var model: AppModel
    var dismiss: () -> Void
    @Environment(\.palette) private var pal

    private func timeAgo(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("notifications")
                .font(.system(size: 13, weight: .heavy))
                .padding(12)
            Divider()
            if model.notifications.isEmpty {
                Text("nothing yet — you'll hear from your agents here")
                    .font(Fonts.uiMono).foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.notifications) { n in
                            Button {
                                model.openNotification(n)
                                dismiss()
                            } label: {
                                HStack(spacing: 8) {
                                    StateDot(state: n.state)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(n.title).font(Fonts.uiMono)
                                        Text("\(n.sub) · \(timeAgo(n.at))")
                                            .font(Fonts.uiMonoSmall).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 320)
    }
}

struct TabChip: View {
    @ObservedObject var model: AppModel
    let ws: WorkspaceState
    let tab: TabState
    let index: Int
    let active: Bool
    @Environment(\.palette) private var pal
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var springTask: Task<Void, Never>?

    private var tabIcon: String {
        if case .pane(let leaf)? = tab.layout, leaf.kind == "world" { return "cube.transparent" }
        if case .pane(let leaf)? = tab.layout, leaf.kind == "web" { return "globe" }
        return "terminal"
    }

    private var tabAgentKind: String? {
        func walk(_ n: LayoutNode?) -> String? {
            switch n {
            case .pane(let l): return l.agent?.kind
            case .split(_, _, let a, let b): return walk(a) ?? walk(b)
            case nil: return nil
            }
        }
        return walk(tab.layout)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let kind = tabAgentKind {
                AgentChip(kind: kind, size: 13)
            } else {
                Image(systemName: tabIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(active ? pal.ink : pal.faint)
            }
            Text(tab.label)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
            if tab.zoomedPaneId != nil {
                Text("ZOOM")
                    .font(.system(size: 8, design: .monospaced)).tracking(1)
                    .padding(.horizontal, 3)
                    .overlay(RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(active ? pal.spotInk : pal.spot, lineWidth: 0.5))
            }
            // slot is always reserved so chips never resize on hover
            Button { model.requestCloseTab(tab) } label: {
                Image(systemName: "xmark").font(.system(size: 7))
                    .frame(width: 10, height: 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 0.75 : 0)
            .allowsHitTesting(hovering)
            .help("Close tab")
        }
        .foregroundStyle(active ? pal.ink : (hovering ? pal.dim : pal.faint))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(UnevenRoundedRectangle(
            topLeadingRadius: 7, bottomLeadingRadius: 0,
            bottomTrailingRadius: 0, topTrailingRadius: 7)
            .fill(active ? pal.mass : (hovering || dropTargeted ? pal.panel : .clear)))
        .overlay(UnevenRoundedRectangle(
            topLeadingRadius: 7, bottomLeadingRadius: 0,
            bottomTrailingRadius: 0, topTrailingRadius: 7)
            .strokeBorder(dropTargeted ? pal.spot : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        // A count:2 gesture stacked on a count:1 makes SwiftUI wait out the whole
        // double-click interval before it will admit a click was single — a fixed
        // ~½s lag on every tab switch. Recognize them in parallel instead: the
        // switch lands on mouse-up, and a second click additionally opens rename.
        .onTapGesture { model.focus(workspaceId: ws.id, tabId: tab.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.activeSheet = .rename(.tab(id: tab.id, current: tab.label))
        })
        .onHover { hovering = $0 }
        .onDrag {
            model.beginDrag("tab:\(tab.id)")
            return PaneDrag.provider("tab:\(tab.id)")
        } preview: {
            DragChip(icon: tabIcon, label: tab.label).environment(\.palette, pal)
        }
        .onDrop(of: [PaneDrag.type], isTargeted: $dropTargeted) { providers in
            model.endDrag()
            loadDragPayload(providers) { payload in
                if payload.hasPrefix("tab:") {
                    let src = String(payload.dropFirst(4))
                    if src != tab.id { model.moveTab(src, toIndex: index) }
                } else if payload.hasPrefix("pane:") {
                    model.movePane(String(payload.dropFirst(5)), toTab: tab.id)
                }
            }
            return true
        }
        // spring-loading: linger over a tab mid-drag and it comes forward, so a
        // dragged pane or tab can be dropped into another tab's layout
        .onChange(of: dropTargeted) { _, targeted in
            springTask?.cancel()
            if targeted && tab.id != ws.focusedTabId {
                springTask = Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if !Task.isCancelled {
                        model.focus(workspaceId: ws.id, tabId: tab.id)
                    }
                }
            }
        }
        .contextMenu {
            Button("Rename tab…") { model.activeSheet = .rename(.tab(id: tab.id, current: tab.label)) }
            Divider()
            Button("Close tab", role: .destructive) { model.requestCloseTab(tab) }
        }
        .help("Click to switch · double-click to rename · drag to reorder")
    }
}

func loadDragPayload(_ providers: [NSItemProvider], _ handle: @escaping (String) -> Void) {
    guard let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(PaneDrag.typeID) }) else { return }
    p.loadDataRepresentation(forTypeIdentifier: PaneDrag.typeID) { data, _ in
        guard let data, let s = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { handle(s) }
    }
}

// MARK: - Pane area (recursive splits)

private struct PanePlacement: Identifiable {
    let leaf: PaneLeaf
    let rect: CGRect
    var id: String { leaf.paneId }
}

private struct DividerPlacement: Identifiable {
    let path: String
    let rect: CGRect
    let horizontal: Bool
    let parentRect: CGRect
    let gap: CGFloat
    var id: String { path }
}

struct PaneAreaView: View {
    @ObservedObject var model: AppModel
    @Environment(\.palette) private var pal

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 8
            let area = CGRect(origin: .zero, size: geo.size).insetBy(dx: inset, dy: inset)
            ZStack(alignment: .topLeading) {
                if let ws = model.focusedWorkspace {
                    // Every tab in the space stays mounted and switching only
                    // changes which one is visible. Rebuilding a tab's panes
                    // re-attaches each SwiftTerm view and re-fires a PTY resize,
                    // which is what made switching feel sluggish.
                    ForEach(ws.tabs, id: \.id) { tab in
                        let isActive = tab.id == ws.focusedTabId
                        tabLayer(tab: tab, area: area, isActive: isActive)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .opacity(isActive ? 1 : 0)
                            .allowsHitTesting(isActive)
                            .zIndex(isActive ? 1 : 0)
                    }
                }
                if model.state != nil && (model.state?.workspaces.isEmpty ?? false) {
                    EmptyStateView(model: model)
                }
            }
        }
        .background(pal.bg)
    }

    @ViewBuilder
    private func tabLayer(tab: TabState, area: CGRect, isActive: Bool) -> some View {
        if let layout = tab.layout {
            let (panes, dividers) = computeLayout(tab: tab, layout: layout, area: area)
            ZStack(alignment: .topLeading) {
                ForEach(panes) { p in
                    let r = CGRect(x: p.rect.minX.rounded(), y: p.rect.minY.rounded(),
                                   width: p.rect.width.rounded(), height: p.rect.height.rounded())
                    PaneView(model: model, tab: tab, leaf: p.leaf,
                             focused: isActive && tab.focusedPaneId == p.leaf.paneId,
                             size: r.size, isActive: isActive)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
                ForEach(dividers) { d in
                    DividerView(model: model, tab: tab, placement: d)
                }
            }
        }
    }

    private func computeLayout(tab: TabState, layout: LayoutNode, area: CGRect)
        -> ([PanePlacement], [DividerPlacement]) {
        var panes: [PanePlacement] = []
        var divs: [DividerPlacement] = []
        if let zoomed = tab.zoomedPaneId, let leaf = layout.leaf(for: zoomed) {
            panes.append(PanePlacement(leaf: leaf, rect: area))
            return (panes, divs)
        }
        walk(node: layout, rect: area, path: "", tab: tab, panes: &panes, divs: &divs)
        return (panes, divs)
    }

    private func walk(node: LayoutNode, rect: CGRect, path: String, tab: TabState,
                      panes: inout [PanePlacement], divs: inout [DividerPlacement]) {
        switch node {
        case .pane(let leaf):
            panes.append(PanePlacement(leaf: leaf, rect: rect))
        case .split(let dir, let serverRatio, let a, let b):
            let gap: CGFloat = 7
            let key = tab.id + "|" + path
            let ratio = model.dragRatios[key] ?? serverRatio
            let childPathA = path.isEmpty ? "a" : path + ".a"
            let childPathB = path.isEmpty ? "b" : path + ".b"
            if dir == "row" {
                let usable = rect.width - gap
                let aw = round(usable * ratio)
                walk(node: a, rect: CGRect(x: rect.minX, y: rect.minY, width: aw, height: rect.height),
                     path: childPathA, tab: tab, panes: &panes, divs: &divs)
                divs.append(DividerPlacement(
                    path: path, rect: CGRect(x: rect.minX + aw, y: rect.minY, width: gap, height: rect.height),
                    horizontal: true, parentRect: rect, gap: gap))
                walk(node: b, rect: CGRect(x: rect.minX + aw + gap, y: rect.minY, width: usable - aw, height: rect.height),
                     path: childPathB, tab: tab, panes: &panes, divs: &divs)
            } else {
                let usable = rect.height - gap
                let ah = round(usable * ratio)
                walk(node: a, rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: ah),
                     path: childPathA, tab: tab, panes: &panes, divs: &divs)
                divs.append(DividerPlacement(
                    path: path, rect: CGRect(x: rect.minX, y: rect.minY + ah, width: rect.width, height: gap),
                    horizontal: false, parentRect: rect, gap: gap))
                walk(node: b, rect: CGRect(x: rect.minX, y: rect.minY + ah + gap, width: rect.width, height: usable - ah),
                     path: childPathB, tab: tab, panes: &panes, divs: &divs)
            }
        }
    }
}

private struct DividerView: View {
    @ObservedObject var model: AppModel
    let tab: TabState
    let placement: DividerPlacement
    @Environment(\.palette) private var pal
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        let d = placement
        Rectangle()
            .fill(Color.clear)
            .frame(width: d.rect.width, height: d.rect.height)
            .overlay {
                RoundedRectangle(cornerRadius: 1)
                    .fill(hovering || dragging ? pal.spot : .clear)
                    .frame(width: d.horizontal ? 2 : nil, height: d.horizontal ? nil : 2)
            }
            .offset(x: d.rect.minX, y: d.rect.minY)
            .contentShape(Rectangle())
            .onHover { h in
                hovering = h
                if h { (d.horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set() }
                else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        dragging = true
                        let key = tab.id + "|" + d.path
                        let pos = d.horizontal
                            ? d.rect.minX + g.translation.width - d.parentRect.minX
                            : d.rect.minY + g.translation.height - d.parentRect.minY
                        let span = (d.horizontal ? d.parentRect.width : d.parentRect.height) - d.gap
                        model.dragRatios[key] = min(0.9, max(0.1, pos / span))
                    }
                    .onEnded { _ in
                        dragging = false
                        let key = tab.id + "|" + d.path
                        if let ratio = model.dragRatios[key] {
                            model.setRatio(tabId: tab.id, path: d.path, ratio: ratio)
                        }
                    })
    }
}

// MARK: - Pane drop (drag to snap / move / swap)

/// What follows the cursor during a drag. SwiftUI's default preview is a
/// full-size translucent snapshot of the grabbed view, which for a pane header
/// is a wide slab that obscures the drop target you are aiming at. cmux shows a
/// small chip instead, and it reads much better.
struct DragChip: View {
    let icon: String
    let label: String
    @Environment(\.palette) private var pal

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11))
            Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(pal.ink)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Palette.Radius.row).fill(pal.mass))
        .overlay(RoundedRectangle(cornerRadius: Palette.Radius.row)
            .strokeBorder(pal.line2, lineWidth: 1))
        .fixedSize()
    }
}

/// Split, zoom and close, shared by every pane kind so a browser or a world
/// pane offers the same controls as a terminal rather than being a dead end.
struct PaneChromeButtons: View {
    @ObservedObject var model: AppModel
    let paneId: String
    var size: CGFloat = 11
    @Environment(\.palette) private var pal

    var body: some View {
        HStack(spacing: 2) {
            btn("terminal", "New terminal tab (⌘T)") {
                if let ws = model.focusedWorkspace { model.newTab(ws) }
            }
            btn("globe", "New browser tab (⇧⌘B)") { model.newBrowserTab() }
            btn("cube.transparent", "New agent world tab (⇧⌘Y)") { model.newWorldTab() }
            btn("rectangle.split.2x1", "Split right (⌘D)") {
                model.splitPane(paneId, direction: "right")
            }
            btn("rectangle.split.1x2", "Split down (⇧⌘D)") {
                model.splitPane(paneId, direction: "down")
            }
            btn("arrow.up.left.and.arrow.down.right", "Zoom pane (⇧⌘E)") {
                model.zoomPane(paneId)
            }
            btn("xmark", "Close pane") { model.requestClosePane(paneId) }
        }
    }

    private func btn(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(pal.faint)
        .help(help)
    }
}

/// Publishes a pane's window-space frame so the model's drop tracker can tell
/// which pane the pointer is over. Kept as its own view with explicit types:
/// inlining it pushed this file past the type-checker's budget.
private struct PaneFrameReporter: View {
    @ObservedObject var model: AppModel
    let paneId: String

    var body: some View {
        GeometryReader { (geo: GeometryProxy) -> Color in
            let f: CGRect = geo.frame(in: .global)
            model.paneFrames[paneId] = f
            return Color.clear
        }
    }
}

// MARK: - Pane chrome

struct PaneView: View {
    @ObservedObject var model: AppModel
    let tab: TabState
    let leaf: PaneLeaf
    let focused: Bool
    let size: CGSize
    var isActive: Bool = true
    @Environment(\.palette) private var pal
    @AppStorage("termTheme") private var termThemeName = "amux"
    @AppStorage("mode") private var mode = "dark"
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            if leaf.kind == "world" {
                WorldToolbar(model: model, paneId: leaf.paneId)
                WorldHost(runtime: model.worldRuntime(for: leaf.paneId), isActive: isActive)
            } else if leaf.kind == "web" {
                BrowserToolbar(runtime: model.webRuntime(for: leaf.paneId),
                               paneId: leaf.paneId, model: model, focused: focused)
                WebHost(runtime: model.webRuntime(for: leaf.paneId),
                        paneId: leaf.paneId, model: model)
            } else {
                header
                TerminalHost(paneTerminal: model.terminal(for: leaf.paneId))
                    .padding(.leading, 6).padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: TermThemes.effective(termThemeName, mode: mode).bgNS))
        .clipShape(RoundedRectangle(cornerRadius: Palette.Radius.card))
        .overlay(dropHighlight)
        .overlay(
            RoundedRectangle(cornerRadius: Palette.Radius.card)
                .strokeBorder(focused ? pal.spot : pal.line2, lineWidth: 1))
        .onHover { hovering = $0 }
        .background(PaneFrameReporter(model: model, paneId: leaf.paneId))
    }

    /// Every pane takes its drop edge from the model's pointer tracking. See
    /// AppModel's "drop tracking" section for why SwiftUI's .onDrop is not used.
    private var activeDropEdge: String? {
        model.trackedDropPane == leaf.paneId ? model.trackedDropEdge : nil
    }

    @ViewBuilder private var dropHighlight: some View {
        if let e = activeDropEdge {
            GeometryReader { geo in
                let r = highlightRect(e, in: geo.size)
                RoundedRectangle(cornerRadius: Palette.Radius.row)
                    .fill(pal.spot.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: Palette.Radius.row).strokeBorder(pal.spot, lineWidth: 1.5))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
            }
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }

    private func highlightRect(_ edge: String, in size: CGSize) -> CGRect {
        switch edge {
        case "left": return CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case "right": return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case "up": return CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case "down": return CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        default: return CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.15, dy: size.height * 0.15)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            if let agent = leaf.agent {
                StateDot(state: agent.state)
                Text(leaf.label ?? agent.name ?? agent.kind)
                    .font(Fonts.uiMonoSmall)
                    .foregroundStyle(focused ? pal.faint : pal.faint2)
                Text("· \(agent.state)\(titleIsKind(agent) ? "" : " · \(agent.kind)")")
                    .font(Fonts.uiMonoSmall)
                    .foregroundStyle(pal.spot)
            } else {
                if let agentKind = leaf.agent?.kind { AgentChip(kind: agentKind, size: 13) }
                Text(leaf.label ?? "❯ \(leaf.proc ?? "shell")")
                    .font(Fonts.uiMonoSmall)
                    .foregroundStyle(focused ? pal.faint : pal.faint2)
            }
            if leaf.kind != "web" {
                if let cwd = leaf.cwd {
                    Text(shortPath(cwd))
                        .font(Fonts.uiMonoSmall)
                        .foregroundStyle(pal.faint2)
                }
                if let branch = leaf.branch {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 8.5))
                        Text(branch).font(Fonts.uiMonoSmall)
                    }
                    .foregroundStyle(pal.spot.opacity(0.9))
                }
            }
            Spacer()
            if hovering { paneButtons }
        }
        .lineLimit(1)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(pal.panel.opacity(0.55))
        .contentShape(Rectangle())
        .onDrag {
            model.beginDrag("pane:\(leaf.paneId)")
            return PaneDrag.provider("pane:\(leaf.paneId)")
        } preview: {
            DragChip(icon: "terminal", label: leaf.label ?? shortPath(leaf.cwd ?? ""))
                .environment(\.palette, pal)
        }
        .contextMenu { paneMenu }
        .help("Drag to move this pane · drop on another pane's edge to snap, middle to swap")
    }

    private func shortPath(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let s = p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
        // keep the tail: the leaf directory is what identifies a pane
        return s.count > 28 ? "…" + s.suffix(27) : s
    }

    private func titleIsKind(_ agent: PaneAgent) -> Bool {
        (leaf.label ?? agent.name ?? agent.kind) == agent.kind
    }

    private var paneButtons: some View {
        HStack(spacing: 2) {
            // starting an agent only means anything in a terminal, so it stays
            // here rather than moving into the cluster every pane kind shares
            headBtn("faceid", "Start agent… (⇧⌘A)") { model.activeSheet = .startAgent(paneId: leaf.paneId) }
            PaneChromeButtons(model: model, paneId: leaf.paneId, size: 9.5)
        }
    }

    private func headBtn(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 9.5))
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(pal.faint)
        .help(help)
    }

    @ViewBuilder private var paneMenu: some View {
        Button("Rename pane…") {
            model.activeSheet = .rename(.pane(id: leaf.paneId, current: leaf.label ?? ""))
        }
        Button("Run command…") { model.activeSheet = .runCommand(paneId: leaf.paneId) }
        Button("Start agent…") { model.activeSheet = .startAgent(paneId: leaf.paneId) }
        Divider()
        Button("Split right") { model.splitPane(leaf.paneId, direction: "right") }
        Button("Split down") { model.splitPane(leaf.paneId, direction: "down") }
        Button("Zoom") { model.zoomPane(leaf.paneId) }
        Divider()
        Menu("Move to space") {
            ForEach(model.state?.workspaces ?? [], id: \.id) { ws in
                Button(ws.label) { model.movePane(leaf.paneId, toWorkspace: ws.id) }
            }
        }
        Divider()
        Button("Send Esc") { model.sendKeys(leaf.paneId, keys: ["esc"]) }
        Button("Send Ctrl+C") { model.sendKeys(leaf.paneId, keys: ["ctrl+c"]) }
        Divider()
        Button("Close pane", role: .destructive) { model.requestClosePane(leaf.paneId) }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    @ObservedObject var model: AppModel
    @Environment(\.palette) private var pal

    var body: some View {
        VStack(spacing: 14) {
            (Text("Give your agents\nsomewhere to ").foregroundColor(pal.ink)
                + Text("live.").foregroundColor(pal.spot))
                .font(.system(size: 28, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("A space is a project directory with tabs and terminal panes inside.\nCreate one, then start agents in any pane — amux watches them\nand tells you who needs you.")
                .font(.system(size: 12))
                .foregroundStyle(pal.faint)
                .multilineTextAlignment(.center)
            Button {
                model.activeSheet = .newSpace
            } label: {
                Text("+ new space")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(pal.spotInk)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: Palette.Radius.row).fill(pal.spot))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
