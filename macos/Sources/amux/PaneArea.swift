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

/// One tab inside a pane's strip. A tab is a pane now, so its identity is the
/// paneId and its label comes from the runtime.
struct TabChip: View {
    @ObservedObject var model: AppModel
    let ws: WorkspaceState
    let group: PaneGroup
    let leaf: PaneLeaf
    let index: Int
    let active: Bool
    @Environment(\.palette) private var pal
    @State private var hovering = false

    private var tabIcon: String {
        switch leaf.kind {
        case "world": return "cube.transparent"
        case "web": return "globe"
        default: return "terminal"
        }
    }

    private var title: String {
        if let label = leaf.label, !label.isEmpty { return label }
        if leaf.kind == "web" { return "New tab" }
        if leaf.kind == "world" { return "agent world" }
        return leaf.proc ?? "shell"
    }

    var body: some View {
        HStack(spacing: 6) {
            if let kind = leaf.agent?.kind {
                AgentChip(kind: kind, size: 13)
            } else {
                Image(systemName: tabIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(active ? pal.ink : pal.faint)
            }
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
            // slot is always reserved so chips never resize on hover
            Button { model.requestClosePane(leaf.paneId) } label: {
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
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(UnevenRoundedRectangle(
            topLeadingRadius: 7, bottomLeadingRadius: 0,
            bottomTrailingRadius: 0, topTrailingRadius: 7)
            .fill(active ? pal.mass : (hovering ? pal.panel : .clear)))
        .contentShape(Rectangle())
        // A count:2 gesture stacked on a count:1 makes SwiftUI wait out the whole
        // double-click interval before it will admit a click was single. Recognize
        // them in parallel instead.
        .onTapGesture { model.focus(workspaceId: ws.id, paneId: leaf.paneId) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.activeSheet = .rename(.pane(id: leaf.paneId, current: leaf.label ?? ""))
        })
        .onHover { hovering = $0 }
        .onDrag {
            model.beginDrag("tab:\(leaf.paneId)")
            return PaneDrag.provider("tab:\(leaf.paneId)")
        } preview: {
            DragChip(icon: tabIcon, label: title).environment(\.palette, pal)
        }
        .background(FrameReporter { model.chipFrames[leaf.paneId] = $0 })
        .contextMenu {
            Button("Rename tab…") {
                model.activeSheet = .rename(.pane(id: leaf.paneId, current: leaf.label ?? ""))
            }
            Divider()
            Button("Close tab", role: .destructive) { model.requestClosePane(leaf.paneId) }
        }
        .help("Click to switch · double-click to rename · drag to reorder or move")
    }
}

func loadDragPayload(_ providers: [NSItemProvider], _ handle: @escaping (String) -> Void) {
    guard let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(PaneDrag.typeID) }) else { return }
    p.loadDataRepresentation(forTypeIdentifier: PaneDrag.typeID) { data, _ in
        guard let data, let s = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { handle(s) }
    }
}

/// A pane's own tab strip, the way cmux arranges things: the tabs belong to
/// this pane, and the create/split cluster acts on it.
struct PaneTabStrip: View {
    @ObservedObject var model: AppModel
    let ws: WorkspaceState
    let group: PaneGroup
    let focused: Bool
    @Environment(\.palette) private var pal

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(group.tabs.enumerated()), id: \.element.paneId) { index, leaf in
                            TabChip(model: model, ws: ws, group: group, leaf: leaf, index: index,
                                    active: leaf.paneId == group.focusedPaneId)
                                .id(leaf.paneId)
                        }
                    }
                }
                .onChange(of: group.focusedPaneId) { _, id in
                    // no animation: the strip should land the instant you click
                    proxy.scrollTo(id)
                }
            }
            Spacer(minLength: 4)
            PaneChromeButtons(model: model, paneId: group.focusedPaneId, size: 10)
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(focused ? pal.panel : pal.panel.opacity(0.6))
        .contentShape(Rectangle())
        .onTapGesture { model.focusGroup(group.groupId) }
        .background(FrameReporter { model.stripFrames[group.groupId] = $0 })
        .overlay(alignment: .leading) { insertCaret }
    }

    /// Where a dragged tab would land in this strip.
    @ViewBuilder private var insertCaret: some View {
        if model.trackedDropGroup == group.groupId, let idx = model.trackedDropIndex {
            GeometryReader { geo in
                let x = caretX(idx, in: geo)
                RoundedRectangle(cornerRadius: 1)
                    .fill(pal.spot)
                    .frame(width: 2)
                    .offset(x: x - 1)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func caretX(_ idx: Int, in geo: GeometryProxy) -> CGFloat {
        let origin = geo.frame(in: .global).minX
        if idx < group.tabs.count, let c = model.chipFrames[group.tabs[idx].paneId] {
            return c.minX - origin
        }
        if let last = group.tabs.last, let c = model.chipFrames[last.paneId] {
            return c.maxX - origin
        }
        return 6
    }
}

// MARK: - Pane area (recursive splits)

private struct GroupPlacement: Identifiable {
    let group: PaneGroup
    let rect: CGRect
    var id: String { group.groupId }
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
                if let ws = model.focusedWorkspace, let layout = ws.layout {
                    let (groups, dividers) = computeLayout(ws: ws, layout: layout, area: area)
                    ForEach(groups) { g in
                        let r = CGRect(x: g.rect.minX.rounded(), y: g.rect.minY.rounded(),
                                       width: g.rect.width.rounded(), height: g.rect.height.rounded())
                        PaneGroupView(model: model, ws: ws, group: g.group,
                                      focused: ws.focusedGroupId == g.group.groupId,
                                      size: r.size)
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                    }
                    ForEach(dividers) { d in
                        DividerView(model: model, ws: ws, placement: d)
                    }
                }
                if model.state != nil && (model.state?.workspaces.isEmpty ?? false) {
                    EmptyStateView(model: model)
                }
            }
        }
        .background(pal.bg)
    }

    private func computeLayout(ws: WorkspaceState, layout: LayoutNode, area: CGRect)
        -> ([GroupPlacement], [DividerPlacement]) {
        var groups: [GroupPlacement] = []
        var divs: [DividerPlacement] = []
        if let zoomed = ws.zoomedGroupId, let g = layout.group(id: zoomed) {
            groups.append(GroupPlacement(group: g, rect: area))
            return (groups, divs)
        }
        walk(node: layout, rect: area, path: "", ws: ws, groups: &groups, divs: &divs)
        return (groups, divs)
    }

    private func walk(node: LayoutNode, rect: CGRect, path: String, ws: WorkspaceState,
                      groups: inout [GroupPlacement], divs: inout [DividerPlacement]) {
        switch node {
        case .group(let g):
            groups.append(GroupPlacement(group: g, rect: rect))
        case .split(let dir, let serverRatio, let a, let b):
            let gap: CGFloat = 7
            let key = ws.id + "|" + path
            let ratio = model.dragRatios[key] ?? serverRatio
            let childPathA = path.isEmpty ? "a" : path + ".a"
            let childPathB = path.isEmpty ? "b" : path + ".b"
            if dir == "row" {
                let usable = rect.width - gap
                let aw = round(usable * ratio)
                walk(node: a, rect: CGRect(x: rect.minX, y: rect.minY, width: aw, height: rect.height),
                     path: childPathA, ws: ws, groups: &groups, divs: &divs)
                divs.append(DividerPlacement(
                    path: path, rect: CGRect(x: rect.minX + aw, y: rect.minY, width: gap, height: rect.height),
                    horizontal: true, parentRect: rect, gap: gap))
                walk(node: b, rect: CGRect(x: rect.minX + aw + gap, y: rect.minY, width: usable - aw, height: rect.height),
                     path: childPathB, ws: ws, groups: &groups, divs: &divs)
            } else {
                let usable = rect.height - gap
                let ah = round(usable * ratio)
                walk(node: a, rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: ah),
                     path: childPathA, ws: ws, groups: &groups, divs: &divs)
                divs.append(DividerPlacement(
                    path: path, rect: CGRect(x: rect.minX, y: rect.minY + ah, width: rect.width, height: gap),
                    horizontal: false, parentRect: rect, gap: gap))
                walk(node: b, rect: CGRect(x: rect.minX, y: rect.minY + ah + gap, width: rect.width, height: usable - ah),
                     path: childPathB, ws: ws, groups: &groups, divs: &divs)
            }
        }
    }
}

/// One pane: its own tab strip on top, the visible tab's content below. Every
/// tab of the group stays mounted and switching only changes which is visible,
/// because rebuilding re-attaches the SwiftTerm view and re-fires a PTY resize.
struct PaneGroupView: View {
    @ObservedObject var model: AppModel
    let ws: WorkspaceState
    let group: PaneGroup
    let focused: Bool
    let size: CGSize
    @Environment(\.palette) private var pal
    @AppStorage("termTheme") private var termThemeName = "amux"
    @AppStorage("mode") private var mode = "dark"

    var body: some View {
        VStack(spacing: 0) {
            PaneTabStrip(model: model, ws: ws, group: group, focused: focused)
            ZStack(alignment: .topLeading) {
                ForEach(group.tabs, id: \.paneId) { leaf in
                    let visible = leaf.paneId == group.focusedPaneId
                    PaneView(model: model, leaf: leaf,
                             focused: focused && visible, size: size, isActive: visible)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .opacity(visible ? 1 : 0)
                        .allowsHitTesting(visible)
                        .zIndex(visible ? 1 : 0)
                }
            }
        }
        .background(Color(nsColor: TermThemes.effective(termThemeName, mode: mode).bgNS))
        .clipShape(RoundedRectangle(cornerRadius: Palette.Radius.card))
        .overlay(dropHighlight)
        .overlay(RoundedRectangle(cornerRadius: Palette.Radius.card)
            .strokeBorder(focused ? pal.spot : pal.line2, lineWidth: 1))
        .background(PaneFrameReporter(model: model, paneId: group.focusedPaneId))
        .contentShape(Rectangle())
        .onTapGesture { model.focusGroup(group.groupId) }
    }

    private var activeDropEdge: String? {
        model.trackedDropPane == group.focusedPaneId ? model.trackedDropEdge : nil
    }

    @ViewBuilder private var dropHighlight: some View {
        if let e = activeDropEdge {
            GeometryReader { geo in
                let r = highlightRect(e, in: geo.size)
                RoundedRectangle(cornerRadius: Palette.Radius.row)
                    .fill(pal.spot.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: Palette.Radius.row)
                        .strokeBorder(pal.spot, lineWidth: 1.5))
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
}

private struct DividerView: View {
    @ObservedObject var model: AppModel
    let ws: WorkspaceState
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
                        let key = ws.id + "|" + d.path
                        let pos = d.horizontal
                            ? d.rect.minX + g.translation.width - d.parentRect.minX
                            : d.rect.minY + g.translation.height - d.parentRect.minY
                        let span = (d.horizontal ? d.parentRect.width : d.parentRect.height) - d.gap
                        model.dragRatios[key] = min(0.9, max(0.1, pos / span))
                    }
                    .onEnded { _ in
                        dragging = false
                        let key = ws.id + "|" + d.path
                        if let ratio = model.dragRatios[key] {
                            model.setRatio(workspaceId: ws.id, path: d.path, ratio: ratio)
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
/// Publishes a view's window-space frame through a closure. Explicit types:
/// inlining a GeometryReader here pushed this file past the type-checker.
struct FrameReporter: View {
    let report: (CGRect) -> Void
    var body: some View {
        GeometryReader { (geo: GeometryProxy) -> Color in
            report(geo.frame(in: .global))
            return Color.clear
        }
    }
}

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

/// The content of one tab. The card, border, drop highlight and frame
/// reporting all belong to the enclosing PaneGroupView now, because those are
/// properties of the pane on screen rather than of whichever tab it is showing.
struct PaneView: View {
    @ObservedObject var model: AppModel
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
                WorldPaneView(runtime: model.worldRuntime(for: leaf.paneId), isActive: isActive)
            } else if leaf.kind == "web" {
                BrowserToolbar(runtime: model.webRuntime(for: leaf.paneId),
                               paneId: leaf.paneId, model: model, focused: focused)
                WebHost(runtime: model.webRuntime(for: leaf.paneId),
                        paneId: leaf.paneId, model: model, isActive: isActive)
            } else {
                header
                TerminalHost(paneTerminal: model.terminal(for: leaf.paneId))
                    .padding(.leading, 6).padding(.vertical, 4)
            }
        }
        .onHover { hovering = $0 }
    }

    /// Slim: the tab chip above already carries the name and agent state, so
    /// this is only the things it cannot show, the working directory and branch.
    private var header: some View {
        HStack(spacing: 7) {
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

    /// Only start-agent: the pane's tab strip carries the shared cluster, so
    /// repeating it here would show every button twice.
    private var paneButtons: some View {
        headBtn("faceid", "Start agent… (⇧⌘A)") {
            model.activeSheet = .startAgent(paneId: leaf.paneId)
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
