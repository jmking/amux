import SwiftUI
import AppKit

// Deterministic native chrome fixture. No terminals, agents, or persisted sessions start.
struct ProofScene: View {
    let light: Bool
    let phase: Int
    @StateObject private var model = AppModel()
    private var pal: Palette { light ? .lightMode : .darkMode }
    private var group: PaneGroup {
        PaneGroup(groupId: "proof", tabs: [
            PaneLeaf(paneId: "one", label: "workspace"),
            PaneLeaf(paneId: "two", label: "review")])
    }
    private var workspace: WorkspaceState {
        WorkspaceState(id: "proof", label: "Pink visual system", cwd: "/projects/amux")
    }
    var body: some View {
        VStack(spacing: 0) {
            Text(light ? "LIGHT APPEARANCE • native chrome fixture" : "DARK APPEARANCE • native chrome fixture")
                .font(.system(size: 11, weight: .semibold)).tracking(1)
                .foregroundStyle(pal.ink).padding(10)
            ZStack {
                HStack(spacing: 0) {
                    SidebarView(model: model)
                    VStack(spacing: 0) {
                        TabBarView(model: model)
                        PaneTabStrip(model: model, ws: workspace, group: group, focused: true)
                        EmptyStateView(model: model)
                    }
                }
                if phase == 1 { CommandPaletteView(model: model) }
                if phase == 2 { NewSpaceSheet(model: model) }
            }
        }
        .frame(width: 1100, height: 560)
        .background(pal.bg)
        .environment(\.palette, pal)
        .preferredColorScheme(light ? .light : .dark)
        .onAppear {
            model.state = ServerState(version: "proof", hostname: "preview",
                focusedWorkspaceId: "proof", workspaces: [workspace,
                    WorkspaceState(id: "other", label: "Documentation", cwd: "/projects/docs")],
                agents: ["working", "idle", "blocked", "done"].enumerated().map { i, state in
                    AgentRow(paneId: "agent\(i)", wsId: "proof", tabId: "tab\(i)",
                        workspace: "Pink visual system", tab: state, kind: "codex",
                        name: state.capitalized, state: state)
                })
        }
    }
}
@main
struct ChromeProof {
    @MainActor static func main() {
        _ = NSApplication.shared
        let phase = Int(CommandLine.arguments[1]) ?? 0

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 1120))
        for light in [false, true] {
            let host = NSHostingView(rootView: ProofScene(light: light, phase: phase))
            host.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            host.frame = NSRect(x: 0, y: light ? 0 : 560, width: 1100, height: 560)
            view.addSubview(host)
        }
        let window = NSWindow(contentRect: view.frame,
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        FileHandle.standardOutput.write(png)
    }
}
