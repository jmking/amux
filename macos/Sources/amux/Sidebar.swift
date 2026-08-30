import SwiftUI
import UniformTypeIdentifiers

struct StateDot: View {
    let state: String
    @Environment(\.palette) private var pal
    @AppStorage("mode") private var mode = "dark"
    @State private var pulsing = false

    var body: some View {
        let color = AgentStateColor.color(state, light: mode == "light")
        Circle()
            .fill(state == "idle" ? Color.clear : color)
            .overlay(Circle().strokeBorder(color, lineWidth: state == "idle" ? 1.5 : 0))
            .frame(width: 8, height: 8)
            .opacity(pulsing && (state == "working" || state == "blocked") ? 0.4 : 1)
            .animation(
                state == "working" || state == "blocked"
                    ? .easeInOut(duration: state == "blocked" ? 0.5 : 0.85).repeatForever(autoreverses: true)
                    : .default,
                value: pulsing)
            .onAppear { pulsing = true }
            .shadow(color: state == "blocked" ? color.opacity(0.6) : .clear, radius: 3)
            .accessibilityLabel("agent state: \(state)")
    }
}

struct SectionHeader: View {
    let title: String
    @Environment(\.palette) private var pal

    var body: some View {
        HStack(spacing: 4) {
            Text("—").foregroundStyle(pal.spot)
            Text(title.uppercased()).tracking(2.2).foregroundStyle(pal.faint2)
        }
        .font(Fonts.uiMonoSmall)
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.palette) private var pal

    var body: some View {
        if model.sidebarCollapsed {
            collapsedRail
        } else {
            expanded
        }
    }

    // Narrow status rail when collapsed: one dot per space.
    private var collapsedRail: some View {
        VStack(spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.15)) { model.sidebarCollapsed = false } } label: {
                Image(systemName: "sidebar.left").font(.system(size: 12))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(pal.faint)
            .help("Show sidebar (⌘0)")
            ForEach(model.state?.workspaces ?? [], id: \.id) { ws in
                Button {
                    model.focus(workspaceId: ws.id)
                } label: {
                    Group {
                        if let icon = ws.icon, !icon.isEmpty { Text(icon).font(.system(size: 12)) }
                        else { StateDot(state: model.workspaceAggregateState(ws)) }
                    }
                    .padding(4)
                    .background(Circle().fill(
                        ws.id == model.state?.focusedWorkspaceId ? pal.mass : .clear))
                }
                .buttonStyle(.plain)
                .help(ws.label)
            }
            Spacer()
        }
        .padding(.top, 10)
        .frame(width: 36)
        .frame(maxHeight: .infinity)
        .background(pal.panel)
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            SectionHeader(title: "spaces")
                            Spacer()
                            Button { model.activeSheet = .newSpace } label: {
                                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(pal.faint)
                            .help("New space (⌘N)")
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 10)

                        if let st = model.state {
                            ForEach(st.workspaces, id: \.id) { ws in
                                SpaceRow(model: model, ws: ws, active: ws.id == st.focusedWorkspaceId)
                            }
                            if st.workspaces.isEmpty {
                                Text("no spaces yet")
                                    .font(Fonts.uiMono).foregroundStyle(pal.faint2)
                                    .padding(.horizontal, 14).padding(.vertical, 4)
                            }
                        }
                    }
                    .tourAnchor(.spaces)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            SectionHeader(title: "agents")
                            Spacer()
                            Button {
                                model.agentSortPriority.toggle()
                            } label: {
                                Text(model.agentSortPriority ? "priority" : "grouped")
                                    .font(Fonts.uiMonoTiny)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .overlay(Capsule().strokeBorder(pal.line2))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(pal.faint2)
                            .help("Toggle agent ordering: grouped by space, or blocked-first attention queue")
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 16)

                        agentRows
                    }
                    .tourAnchor(.agents)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 250)
        .background(pal.panel)
    }


    @ViewBuilder private var agentRows: some View {
        let agents = model.state?.agents ?? []
        if agents.isEmpty {
            Text("No live agents")
                .font(Fonts.uiMono).foregroundStyle(pal.faint2)
                .padding(.horizontal, 14).padding(.vertical, 4)
        } else if model.agentSortPriority {
            let order = ["blocked": 0, "done": 1, "working": 2, "idle": 3, "unknown": 4]
            ForEach(agents.sorted { (order[$0.state] ?? 9) < (order[$1.state] ?? 9) }) { a in
                AgentRowView(model: model, agent: a)
            }
        } else {
            ForEach(model.state?.workspaces ?? [], id: \.id) { ws in
                let mine = agents.filter { $0.wsId == ws.id }
                if !mine.isEmpty {
                    if (model.state?.workspaces.count ?? 0) > 1 {
                        Text(ws.label.uppercased())
                            .font(Fonts.uiMonoTiny).tracking(1.5)
                            .foregroundStyle(pal.faint2)
                            .padding(.horizontal, 14).padding(.top, 6)
                    }
                    ForEach(mine) { a in AgentRowView(model: model, agent: a) }
                }
            }
        }
    }

}

struct SpaceRow: View {
    @ObservedObject var model: AppModel
    let ws: WorkspaceState
    let active: Bool
    @Environment(\.palette) private var pal
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon = ws.icon, !icon.isEmpty {
                Text(icon).font(.system(size: 13))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(ws.label)
                    .font(Fonts.uiMono)
                    .foregroundStyle(active ? pal.ink : pal.dim)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let git = ws.git {
                        Text(git.branch)
                        // both badges use SF Symbols at one size/weight: the
                        // ✚ and ↑ text glyphs have very different stroke weights
                        if git.dirty > 0 { gitBadge("plus", git.dirty, AgentStateColor.color("working")) }
                        if git.ahead > 0 { gitBadge("arrow.up", git.ahead, AgentStateColor.color("idle")) }
                        if git.behind > 0 { gitBadge("arrow.down", git.behind, pal.faint2) }
                    } else {
                        Text(shortPath(ws.cwd))
                    }
                }
                .font(Fonts.uiMonoSmall)
                .foregroundStyle(pal.faint2)
                .lineLimit(1)
            }
            Spacer()
            if hovering {
                Button { model.requestCloseSpace(ws) } label: {
                    Image(systemName: "xmark").font(.system(size: 8))
                }
                .buttonStyle(.plain).foregroundStyle(pal.faint2)
                .help("Close space")
            } else {
                StateDot(state: model.workspaceAggregateState(ws))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(active || hovering || dropTargeted ? pal.mass : .clear))
        .overlay(alignment: .leading) {
            if active {
                RoundedRectangle(cornerRadius: 1).fill(pal.spot)
                    .frame(width: 2).padding(.vertical, 5)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(dropTargeted ? pal.spot : .clear, lineWidth: 1.5))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.focus(workspaceId: ws.id) }
        .onHover { hovering = $0 }
        .onDrop(of: [PaneDrag.type], isTargeted: $dropTargeted) { providers in
            model.endDrag()
            loadDragPayload(providers) { payload in
                if payload.hasPrefix("pane:") {
                    model.movePane(String(payload.dropFirst(5)), toWorkspace: ws.id)
                }
            }
            return true
        }
        .contextMenu {
            Button("Rename space…") { model.activeSheet = .rename(.space(id: ws.id, current: ws.label)) }
            Button("Set emoji…") { model.activeSheet = .spaceEmoji(ws) }
            Button("New tab here") {
                model.focus(workspaceId: ws.id)
                model.newTab(ws)
            }
            Button("New worktree from here…") { model.activeSheet = .newWorktree(repo: ws.cwd) }
            Divider()
            Button("Close space", role: .destructive) { model.requestCloseSpace(ws) }
        }
        .help("Drop a pane here to move it into this space")
    }

    private func gitBadge(_ symbol: String, _ count: Int, _ color: SwiftUI.Color) -> some View {
        HStack(spacing: 1) {
            Image(systemName: symbol).font(.system(size: 8, weight: .semibold))
            Text("\(count)")
        }
        .foregroundStyle(color)
    }

    private func shortPath(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let s = p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
        return s.count > 30 ? "…" + s.suffix(29) : s
    }
}

struct AgentRowView: View {
    @ObservedObject var model: AppModel
    let agent: AgentRow
    @Environment(\.palette) private var pal
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            AgentChip(kind: agent.kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name ?? agent.tab)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(pal.dim).lineLimit(1)
                Text("\(agent.kind) · \(agent.state)")
                    .font(Fonts.uiMonoSmall).foregroundStyle(pal.faint2).lineLimit(1)
            }
            Spacer()
            StateDot(state: agent.state)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? pal.mass : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            model.focus(workspaceId: agent.wsId, tabId: agent.tabId, paneId: agent.paneId)
        }
        .onHover { hovering = $0 }
        .help("Jump to this agent")
    }
}
