import SwiftUI

struct PaletteAction: Identifiable {
    let label: String
    let kind: String
    let act: () -> Void
    var id: String { kind + "|" + label }
}

struct CommandPaletteView: View {
    @ObservedObject var model: AppModel
    @Environment(\.palette) private var pal
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("type a command or jump to a space, tab, or agent…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(pal.ink)
                .padding(14)
                .focused($focused)
                .onSubmit { runSelected() }
                .onChange(of: query) { _, _ in selection = 0 }
            Divider().overlay(pal.line2)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { i, action in
                        HStack {
                            Text(action.label).font(Fonts.uiMono)
                            Spacer()
                            Text(action.kind.uppercased())
                                .font(Fonts.uiMonoTiny).tracking(1)
                                .foregroundStyle(pal.faint2)
                        }
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(i == selection ? pal.mass : .clear))
                        .foregroundStyle(i == selection ? pal.ink : pal.dim)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.paletteOpen = false
                            action.act()
                        }
                        .onHover { if $0 { selection = i } }
                    }
                }
                .padding(5)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 540)
        .background(pal.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(pal.line2))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(0, matches.count - 1)); return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0); return .handled
        }
        .onKeyPress(.escape) {
            model.paletteOpen = false; return .handled
        }
    }

    private var matches: [PaletteAction] {
        let q = query.lowercased()
        let all = buildActions()
        if q.isEmpty { return Array(all.prefix(14)) }
        return Array(all.filter { $0.label.lowercased().contains(q) }.prefix(14))
    }

    private func runSelected() {
        let m = matches
        guard selection < m.count else { return }
        model.paletteOpen = false
        m[selection].act()
    }

    private func buildActions() -> [PaletteAction] {
        var acts: [PaletteAction] = []
        let focusPane = model.focusedTab?.focusedPaneId
        acts.append(PaletteAction(label: "new space…", kind: "action") { model.activeSheet = .newSpace })
        acts.append(PaletteAction(label: "new worktree…", kind: "action") {
            model.activeSheet = .newWorktree(repo: model.focusedWorkspace?.cwd)
        })
        if let ws = model.focusedWorkspace {
            acts.append(PaletteAction(label: "new tab", kind: "action") { model.newTab(ws) })
            acts.append(PaletteAction(label: "new browser tab", kind: "action") { model.newBrowserTab() })
        }
        if let p = focusPane {
            acts.append(PaletteAction(label: "split right", kind: "pane") { model.splitPane(p, direction: "right") })
            acts.append(PaletteAction(label: "split down", kind: "pane") { model.splitPane(p, direction: "down") })
            acts.append(PaletteAction(label: "browser in a split", kind: "pane") { model.splitPaneWithBrowser(p, direction: "right") })
            acts.append(PaletteAction(label: "zoom pane", kind: "pane") { model.zoomPane(p) })
            acts.append(PaletteAction(label: "start agent…", kind: "pane") { model.activeSheet = .startAgent(paneId: p) })
            acts.append(PaletteAction(label: "run command…", kind: "pane") { model.activeSheet = .runCommand(paneId: p) })
            acts.append(PaletteAction(label: "rename pane…", kind: "pane") {
                model.activeSheet = .rename(.pane(id: p, current: ""))
            })
            acts.append(PaletteAction(label: "close pane", kind: "pane") { model.requestClosePane(p) })
        }
        acts.append(PaletteAction(label: "toggle sidebar", kind: "action") { model.sidebarCollapsed.toggle() })
        acts.append(PaletteAction(label: "toggle light / dark", kind: "action") {
            let d = UserDefaults.standard
            d.set((d.string(forKey: "mode") ?? "dark") == "dark" ? "light" : "dark", forKey: "mode")
        })
        if let st = model.state {
            for ws in st.workspaces {
                acts.append(PaletteAction(label: "go to space: \(ws.label)", kind: "space") {
                    model.focus(workspaceId: ws.id)
                })
                for tab in ws.tabs {
                    acts.append(PaletteAction(label: "go to tab: \(ws.label) / \(tab.label)", kind: "tab") {
                        model.focus(workspaceId: ws.id, tabId: tab.id)
                    })
                }
            }
            for a in st.agents {
                acts.append(PaletteAction(label: "go to agent: \(a.name ?? a.kind) (\(a.workspace))", kind: "agent") {
                    model.focus(workspaceId: a.wsId, tabId: a.tabId, paneId: a.paneId)
                })
            }
        }
        return acts
    }
}
