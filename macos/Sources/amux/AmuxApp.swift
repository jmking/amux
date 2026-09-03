import SwiftUI
import AppKit
import UserNotifications

@main
struct AmuxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()
    @AppStorage("mode") private var mode = "dark"

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .environment(\.palette, mode == "light" ? .lightMode : .darkMode)
                .preferredColorScheme(mode == "light" ? .light : .dark)
                .onAppear {
                    model.start()
                    appDelegate.model = model
                }
                .onChange(of: mode) { _, _ in
                    let theme = TermThemes.effectiveFromDefaults()
                    for term in model.runtimes.values { term.applyTheme(theme) }
                }
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands { commands }

        Settings {
            SettingsView(model: model)
                .environment(\.palette, mode == "light" ? .lightMode : .darkMode)
        }
    }

    @CommandsBuilder private var commands: some Commands {
        // File
        CommandGroup(replacing: .newItem) {
            Button("New Space…") { model.activeSheet = .newSpace }
                .keyboardShortcut("n")
            Button("New Tab") {
                if let ws = model.focusedWorkspace { model.newTab(ws) }
                else { model.activeSheet = .newSpace }
            }
            .keyboardShortcut("t")
            Button("New Browser Tab") { model.newBrowserTab() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("New Worktree…") {
                model.activeSheet = .newWorktree(repo: model.focusedWorkspace?.cwd)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Rename Space…") {
                if let ws = model.focusedWorkspace {
                    model.activeSheet = .rename(.space(id: ws.id, current: ws.label))
                }
            }
            Button("Rename Tab…") {
                if let p = model.focusedWorkspace?.focusedPaneId {
                    model.activeSheet = .rename(.pane(id: p, current: ""))
                }
            }
            Divider()
            Button("Close Pane") {
                if let p = model.focusedWorkspace?.focusedPaneId { model.requestClosePane(p) }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            Button("Close Group") {
                if let g = model.focusedGroup { model.requestCloseGroup(g) }
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
            Button("Close Space") {
                if let ws = model.focusedWorkspace { model.requestCloseSpace(ws) }
            }
        }

        // View
        CommandGroup(after: .toolbar) {
            Button("Command Palette…") { model.paletteOpen = true }
                .keyboardShortcut("k")
            Button(model.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") {
                model.toggleSidebar()
            }
            .keyboardShortcut("0")
            Button(mode == "dark" ? "Switch to Light Mode" : "Switch to Dark Mode") {
                mode = mode == "dark" ? "light" : "dark"
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Next Tab") { model.stepTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { model.stepTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            ForEach(1...9, id: \.self) { i in
                Button("Tab \(i)") { model.selectTab(index: i - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: .command)
            }
            Divider()
            ForEach(1...9, id: \.self) { i in
                Button("Space \(i)") { model.selectSpace(index: i - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: [.command, .option])
            }
            Divider()
            Button("Open Latest Notification") { model.openLatestNotification() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        // Pane
        CommandMenu("Pane") {
            Button("Split Right") {
                if let p = model.actionPaneId { model.splitPane(p, direction: "right") }
            }
            .keyboardShortcut("d")
            Button("Split Down") {
                if let p = model.actionPaneId { model.splitPane(p, direction: "down") }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Zoom Pane") {
                if let p = model.actionPaneId { model.zoomPane(p) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Button("Focus Left") { model.focusDirection("left") }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Focus Right") { model.focusDirection("right") }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Focus Up") { model.focusDirection("up") }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Focus Down") { model.focusDirection("down") }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button("Run Command…") {
                if let p = model.actionPaneId { model.activeSheet = .runCommand(paneId: p) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Start Agent…") {
                if let p = model.actionPaneId { model.activeSheet = .startAgent(paneId: p) }
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Button("Send Esc") {
                if let p = model.focusedWorkspace?.focusedPaneId {
                    model.sendKeys(p, keys: ["esc"])
                }
            }
            Button("Send Ctrl+C") {
                if let p = model.focusedWorkspace?.focusedPaneId {
                    model.sendKeys(p, keys: ["ctrl+c"])
                }
            }
        }

        CommandGroup(replacing: .appInfo) {
            Button("About amux") { AboutWindow.shared.show(mode: mode) }
        }

        CommandGroup(after: .newItem) {
            Button("New Agent World Tab") { model.newWorldTab() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Button("Toggle Agent World Demo") { model.toggleWorldDemo() }
        }

        // Help
        CommandGroup(replacing: .help) {
            Button("amux on GitHub") { NSWorkspace.shared.open(amuxRepoURL) }
        }
    }
}

/// macOS swallows the first click into an inactive window, so toolbar buttons
/// need two clicks — wrong for a terminal you glance at and poke. Give the
/// SwiftUI hosting view an isa-swizzled subclass that accepts first mouse.
@MainActor
func acceptFirstMouse(_ view: NSView) {
    let base: AnyClass = type(of: view)
    let name = "AmuxFirstMouse_" + NSStringFromClass(base)
    if let existing = NSClassFromString(name) {
        if !view.isKind(of: existing) { object_setClass(view, existing) }
        return
    }
    guard let subclass = objc_allocateClassPair(base, name, 0) else { return }
    let block: @convention(block) (AnyObject, NSEvent?) -> Bool = { _, _ in true }
    class_addMethod(subclass,
                    #selector(NSView.acceptsFirstMouse(for:)),
                    imp_implementationWithBlock(block),
                    "c@:@")
    objc_registerClassPair(subclass)
    object_setClass(view, subclass)
}

/// Holds the live drag session so the drop tracker can decide whether the drag
/// image slides home.
///
/// AppKit slides a drag image back to where it started whenever a drag ends
/// without an AppKit drop. amux never accepts one through AppKit's protocol --
/// drags have to cross WKWebView panes, which AppKit will not route into, so a
/// pointer tracker applies the drop instead. Every successful drag therefore
/// also looked like a failure, and the tab graphic flew back to its old spot
/// while the panes were already animating into their new places.
///
/// SwiftUI owns the session and .onDrag does not hand it over, so take it from
/// the only place it appears: the NSView call that creates it.
@MainActor
enum DragSession {
    static weak var current: NSDraggingSession?
    private static var installed = false

    static func installSlideBackControl() {
        guard !installed else { return }
        installed = true
        let sel = #selector(NSView.beginDraggingSession(with:event:source:))
        guard let method = class_getInstanceMethod(NSView.self, sel) else { return }
        typealias Original = @convention(c)
            (AnyObject, Selector, [NSDraggingItem], NSEvent, any NSDraggingSource) -> NSDraggingSession
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let block: @convention(block)
            (AnyObject, [NSDraggingItem], NSEvent, any NSDraggingSource) -> NSDraggingSession = {
                view, items, event, source in
                let session = original(view, sel, items, event, source)
                MainActor.assumeIsolated { DragSession.current = session }
                return session
            }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// A drag heading somewhere real should just land; one heading nowhere should
    /// still visibly return, so the gesture reads as refused rather than lost.
    static func setWillLand(_ landing: Bool) {
        current?.animatesToStartingPositionsOnCancelOrFail = !landing
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    var model: AppModel? {
        didSet { observeAgents() }
    }
    private var statusItem: NSStatusItem?
    private var agentsCancellable: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // themes used to be called ink/paper; carry an existing choice over
        let d = UserDefaults.standard
        if let old = d.string(forKey: "mode"), old == "ink" || old == "paper" {
            d.set(old == "paper" ? "light" : "dark", forKey: "mode")
        }
        UNUserNotificationCenter.current().delegate = self
        setupStatusItem()
        DragSession.installSlideBackControl()
        // Pane/tab drags must never turn into window moves: macOS treats
        // non-interactive chrome as a window-drag handle by default.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let window = note.object as? NSWindow, window.canBecomeMain {
                    window.isMovableByWindowBackground = false
                    if let content = window.contentView { acceptFirstMouse(content) }
                }
            }
        }
        // also catch the very first window, which may already be key
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            for window in NSApp.windows where window.canBecomeMain {
                window.isMovableByWindowBackground = false
                if let content = window.contentView { acceptFirstMouse(content) }
            }
        }
        // Launch sometimes comes up windowless (SwiftUI restoration quirk);
        // poking SwiftUI's reopen handler materializes the WindowGroup, same as
        // clicking the Dock icon. Retry a few times — too early races scene setup.
        for delay in [1.0, 2.5, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.ensureMainWindow()
            }
        }
    }

    // closing the window keeps agents running; the menu bar item is the app's home
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let model, model.busyAgentCount > 0 {
            let alert = NSAlert()
            alert.messageText = "\(model.busyAgentCount) agent\(model.busyAgentCount == 1 ? " is" : "s are") still working"
            alert.informativeText = "Quitting amux stops every terminal and agent."
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        model?.shutdown()
        return .terminateNow
    }

    static func ensureMainWindow() {
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
            return
        }
        if let delegate = NSApp.delegate {
            _ = delegate.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: menu bar extra — every agent at a glance

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        updateStatusTitle()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    private func observeAgents() {
        guard let model else { return }
        agentsCancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusTitle() }
        }
    }

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        let agents = model?.state?.agents ?? []
        let blocked = agents.filter { $0.state == "blocked" }.count
        let working = agents.filter { $0.state == "working" }.count
        let done = agents.filter { $0.state == "done" }.count
        let title = NSMutableAttributedString(
            string: "❯a",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)])
        func dot(_ color: NSColor, _ count: Int) {
            guard count > 0 else { return }
            title.append(NSAttributedString(
                string: " ●\(count > 1 ? "\(count)" : "")",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
                             .foregroundColor: color]))
        }
        dot(NSColor(hex: 0xc73e3e), blocked)
        dot(NSColor(hex: 0x94e2d5), done)
        dot(NSColor(hex: 0xd3a027), working)
        button.attributedTitle = title
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let agents = model?.state?.agents ?? []
        if agents.isEmpty {
            let it = NSMenuItem(title: "no live agents", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        } else {
            let order = ["blocked": 0, "done": 1, "working": 2, "idle": 3, "unknown": 4]
            for a in agents.sorted(by: { (order[$0.state] ?? 9) < (order[$1.state] ?? 9) }) {
                let stateColor: NSColor = switch a.state {
                case "blocked": NSColor(hex: 0xc73e3e)
                case "working": NSColor(hex: 0xd3a027)
                case "done": NSColor(hex: 0x94e2d5)
                case "idle": NSColor(hex: 0x5fae74)
                default: NSColor(hex: 0x908f96)
                }
                let label = NSMutableAttributedString(
                    string: "● ",
                    attributes: [.foregroundColor: stateColor,
                                 .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)])
                label.append(NSAttributedString(
                    string: "\(a.name ?? a.kind) — \(a.state) · \(a.kind)  (\(a.workspace))",
                    attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]))
                let it = NSMenuItem(title: "", action: #selector(jumpToAgent(_:)), keyEquivalent: "")
                it.attributedTitle = label
                it.target = self
                it.representedObject = ["wsId": a.wsId, "tabId": a.tabId, "paneId": a.paneId]
                menu.addItem(it)
            }
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Show amux", action: #selector(openApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "Quit amux (stops all agents)", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func jumpToAgent(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String] else { return }
        NSApp.activate(ignoringOtherApps: true)
        model?.focus(workspaceId: info["wsId"], paneId: info["paneId"])
    }

    @objc private func openApp() {
        Self.ensureMainWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let wsId = info["wsId"] as? String else { return }
        let paneId = info["paneId"] as? String
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            model?.focus(workspaceId: wsId, paneId: paneId)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.palette) private var pal

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                SidebarView(model: model)
                Divider().overlay(pal.line2)
                VStack(spacing: 0) {
                    TabBarView(model: model)
                    Divider().overlay(pal.line2)
                    PaneAreaView(model: model)
                }
            }
            if model.paletteOpen {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { model.paletteOpen = false }
                VStack {
                    CommandPaletteView(model: model)
                        .padding(.top, 70)
                    Spacer()
                }
            }
        }
        .background(pal.bg)
        .sheet(item: $model.activeSheet) { sheet in
            sheetView(sheet)
                .environment(\.palette, pal)
        }
        .alert("amux", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    @ViewBuilder private func sheetView(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .newSpace: NewSpaceSheet(model: model)
        case .startAgent(let paneId): StartAgentSheet(model: model, paneId: paneId)
        case .runCommand(let paneId): RunCommandSheet(model: model, paneId: paneId)
        case .newWorktree(let repo): NewWorktreeSheet(model: model, initialRepo: repo)
        case .confirmCloseSpace(let ws): ConfirmCloseSpaceSheet(model: model, ws: ws)
        case .confirmCloseGroup(let g): ConfirmCloseGroupSheet(model: model, group: g)
        case .confirmClosePane(let paneId, let agent):
            ConfirmClosePaneSheet(model: model, paneId: paneId, agent: agent)
        case .rename(let target): RenameSheet(model: model, target: target)
        case .spaceEmoji(let ws): SpaceEmojiSheet(model: model, ws: ws)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("mode") private var mode = "dark"
    @AppStorage("termTheme") private var termTheme = "amux"
    @AppStorage("termFontSize") private var termFontSize = 12.5
    @AppStorage("confirmClose") private var confirmClose = true
    @AppStorage("notifSounds") private var notifSounds = true

    var body: some View {
        Form {
            Picker("Appearance", selection: $mode) {
                Text("Dark").tag("dark")
                Text("Light").tag("light")
            }
            .pickerStyle(.segmented)

            Picker("Terminal theme", selection: $termTheme) {
                ForEach(TermThemes.all) { t in Text(t.name).tag(t.name) }
            }
            .onChange(of: termTheme) { _, _ in reapplyTerminalStyles() }

            Slider(value: $termFontSize, in: 10...18, step: 0.5) {
                Text("Font size (\(termFontSize, specifier: "%.1f")px)")
            }
            .onChange(of: termFontSize) { _, _ in reapplyTerminalStyles() }

            Toggle("Confirm before closing", isOn: $confirmClose)
            Toggle("Notification sounds", isOn: $notifSounds)

                .font(Fonts.uiMono)
        }
        .padding(20)
        .frame(width: 420)
    }

    private func reapplyTerminalStyles() {
        let theme = TermThemes.effective(termTheme, mode: mode)
        for term in model.runtimes.values { term.applyTheme(theme) }
    }
}
