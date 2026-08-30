import SwiftUI
import AppKit

private func chooseDirectory(start: String? = nil, completion: @escaping (String) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    if let start { panel.directoryURL = URL(fileURLWithPath: (start as NSString).expandingTildeInPath) }
    if panel.runModal() == .OK, let url = panel.url {
        completion(url.path)
    }
}

struct SheetChrome<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.palette) private var pal

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: title)
            content
        }
        .padding(18)
        .frame(width: 440)
    }
}

// MARK: - New space

struct NewSpaceSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var dir = NSString(string: "~").expandingTildeInPath

    var body: some View {
        SheetChrome("new space") {
            TextField("space name (defaults to folder name)", text: $name)
                .textFieldStyle(.roundedBorder).font(Fonts.uiMono)
            HStack {
                TextField("directory", text: $dir)
                    .textFieldStyle(.roundedBorder).font(Fonts.uiMono)
                Button("Choose…") { chooseDirectory(start: dir) { dir = $0 } }
            }
            if FileManager.default.fileExists(atPath: dir + "/.git") {
                Label("git repo", systemImage: "checkmark.circle")
                    .font(Fonts.uiMonoSmall).foregroundStyle(AgentStateColor.color("idle"))
            }
            HStack {
                Spacer()
                Button("cancel") { dismiss() }
                Button("create space") {
                    model.createWorkspace(label: name.trimmingCharacters(in: .whitespaces), cwd: dir)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Start agent

struct StartAgentSheet: View {
    @ObservedObject var model: AppModel
    let paneId: String
    @Environment(\.dismiss) private var dismiss
    @State private var kinds: [(kind: String, installed: Bool)] = []
    @State private var kind = "claude"
    @State private var name = ""
    @State private var args = ""
    @State private var location = "current"

    var body: some View {
        SheetChrome("start agent") {
            Picker("agent", selection: $kind) {
                ForEach(kinds, id: \.kind) { k in
                    Text(k.kind + (k.installed ? "  ✓" : "  (not on PATH)")).tag(k.kind)
                }
            }
            TextField("optional name, e.g. reviewer", text: $name)
                .textFieldStyle(.roundedBorder).font(Fonts.uiMono)
            TextField("extra CLI args (optional)", text: $args)
                .textFieldStyle(.roundedBorder).font(Fonts.uiMono)
            Picker("where", selection: $location) {
                Text("in this pane").tag("current")
                Text("in a new split (right)").tag("right")
                Text("in a new split (down)").tag("down")
            }
            HStack {
                Spacer()
                Button("cancel") { dismiss() }
                Button("start") {
                    startAgent()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .task {
            kinds = await model.fetchAgentKinds()
            if let first = kinds.first(where: { $0.installed }) { kind = first.kind }
        }
    }

    private func startAgent() {
        let agentName = name.trimmingCharacters(in: .whitespaces)
        var target = paneId
        if location != "current", let newId = model.splitPane(paneId, direction: location) {
            target = newId
        }
        // give a fresh split's shell a beat to reach its prompt
        let delay = location == "current" ? 0.0 : 0.6
        let kindNow = kind, argsNow = args
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            model.startAgent(paneId: target, kind: kindNow,
                             name: agentName.isEmpty ? nil : agentName, args: argsNow)
        }
    }
}

// MARK: - Run command

struct RunCommandSheet: View {
    @ObservedObject var model: AppModel
    let paneId: String
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""

    var body: some View {
        SheetChrome("run command") {
            TextField("e.g. npm test", text: $command)
                .textFieldStyle(.roundedBorder).font(Fonts.uiMono)
            Text("sent to the pane followed by Enter")
                .font(Fonts.uiMonoSmall).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("cancel") { dismiss() }
                Button("run") {
                    let cmd = command.trimmingCharacters(in: .whitespaces)
                    if !cmd.isEmpty { model.runCommand(paneId, command: cmd) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - New worktree

struct NewWorktreeSheet: View {
    @ObservedObject var model: AppModel
    let initialRepo: String?
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ""
    @State private var branch = ""
    @State private var base = ""

    var body: some View {
        SheetChrome("new worktree") {
            HStack {
                TextField("path to git repo", text: $repo)
                    .textFieldStyle(.roundedBorder).font(Fonts.uiMono)
                Button("Choose…") { chooseDirectory(start: repo.isEmpty ? nil : repo) { repo = $0 } }
            }
            TextField("new branch name", text: $branch)
                .textFieldStyle(.roundedBorder).font(Fonts.uiMono)
            TextField("base ref (default HEAD)", text: $base)
                .textFieldStyle(.roundedBorder).font(Fonts.uiMono)
            Text("a new branch and worktree are created, then opened as a space")
                .font(Fonts.uiMonoSmall).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("cancel") { dismiss() }
                Button("create worktree") {
                    let baseRef = base.trimmingCharacters(in: .whitespaces)
                    model.createWorktree(repo: repo, branch: branch.trimmingCharacters(in: .whitespaces),
                                         base: baseRef.isEmpty ? nil : baseRef)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(repo.isEmpty || branch.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { if let initialRepo { repo = initialRepo } }
    }
}

// MARK: - Rename

struct RenameSheet: View {
    @ObservedObject var model: AppModel
    let target: RenameTarget
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var title: String {
        switch target {
        case .space: return "rename space"
        case .tab: return "rename tab"
        case .pane: return "rename pane"
        }
    }

    var body: some View {
        SheetChrome(title) {
            TextField("name", text: $name)
                .textFieldStyle(.roundedBorder).font(Fonts.uiMono)
            if case .pane = target {
                Text("leave empty to go back to showing the running program")
                    .font(Fonts.uiMonoSmall).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("save") {
                    let label = name.trimmingCharacters(in: .whitespaces)
                    switch target {
                    case .space(let id, _):
                        if !label.isEmpty { model.renameSpace(id, label: label) }
                    case .tab(let id, _):
                        if !label.isEmpty { model.renameTab(id, label: label) }
                    case .pane(let id, _):
                        model.renamePane(id, label: label)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            switch target {
            case .space(_, let cur), .tab(_, let cur), .pane(_, let cur): name = cur
            }
        }
    }
}

// MARK: - Space emoji

struct SpaceEmojiSheet: View {
    @ObservedObject var model: AppModel
    let ws: WorkspaceState
    @Environment(\.dismiss) private var dismiss
    @State private var emoji = ""

    private let quick = ["🐏", "🚀", "🔧", "🧪", "📦", "🌿", "🔥", "🧠", "🛰️", "📊", "🎨", "🕸️"]

    var body: some View {
        SheetChrome("space emoji") {
            HStack(spacing: 6) {
                ForEach(quick, id: \.self) { e in
                    Button(e) { emoji = e }
                        .buttonStyle(.plain).font(.system(size: 18))
                }
            }
            TextField("emoji (or clear to use the state dot)", text: $emoji)
                .textFieldStyle(.roundedBorder).font(Fonts.uiMono)
            HStack {
                Spacer()
                Button("cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("save") {
                    model.setSpaceIcon(ws.id, icon: emoji.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { emoji = ws.icon ?? "" }
    }
}

// MARK: - Confirmations

struct ConfirmCloseSpaceSheet: View {
    @ObservedObject var model: AppModel
    let ws: WorkspaceState
    @Environment(\.dismiss) private var dismiss
    @State private var removeWorktree = false

    var body: some View {
        SheetChrome("close space") {
            Text("Close “\(ws.label)” and stop everything running inside it?")
                .font(.system(size: 12.5))
            if ws.worktree {
                Toggle("also remove its git worktree", isOn: $removeWorktree)
                    .font(Fonts.uiMono)
            }
            HStack {
                Spacer()
                Button("cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("close space", role: .destructive) {
                    model.closeWorkspace(ws.id, removeWorktree: removeWorktree)
                    dismiss()
                }
            }
        }
    }
}

struct ConfirmCloseTabSheet: View {
    @ObservedObject var model: AppModel
    let tab: TabState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetChrome("close tab") {
            Text("Close “\(tab.label)” and its \(tab.layout?.paneIds.count ?? 0) panes?")
                .font(.system(size: 12.5))
            HStack {
                Spacer()
                Button("cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("close tab", role: .destructive) {
                    model.closeTab(tab.id)
                    dismiss()
                }
            }
        }
    }
}

struct ConfirmClosePaneSheet: View {
    @ObservedObject var model: AppModel
    let paneId: String
    let agent: PaneAgent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetChrome("close pane") {
            Text("This pane is running \(agent.kind) (\(agent.state)). Close it anyway?")
                .font(.system(size: 12.5))
            HStack {
                Spacer()
                Button("cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("close pane", role: .destructive) {
                    model.closePane(paneId)
                    dismiss()
                }
            }
        }
    }
}
