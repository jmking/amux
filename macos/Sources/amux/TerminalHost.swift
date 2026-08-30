import SwiftUI
import AppKit
import SwiftTerm

/// One pane = one PTY + one persistent SwiftTerm view, all in-process.
/// Bridges TerminalViewDelegate (user input, resizes) and LocalProcessDelegate
/// (pty output, exit) and owns the pane's runtime metadata.
@MainActor
final class PaneRuntime: NSObject {
    let id: String
    weak var model: AppModel?
    let view: TerminalView
    /// Owned once and handed to SwiftUI as-is: re-parenting a SwiftTerm view on
    /// every tab switch forces a full terminal redraw.
    lazy var container: NSView = {
        let c = NSView()
        view.frame = c.bounds
        view.autoresizingMask = [.width, .height]
        c.addSubview(view)
        return c
    }()
    private var process: LocalProcess?

    var label: String?
    var procName: String = "shell"
    /// Updated in the background by the detect tick — never block the main
    /// thread on lsof (it costs ~35ms per pane).
    var cachedCwd: String?
    var agent: PaneAgent?
    var lastOutputAt = Date.distantPast
    private var cols: UInt16 = 120
    private var rows: UInt16 = 32
    private var exited = false

    var shellPid: pid_t { process?.shellPid ?? 0 }

    init(id: String, cwd: String, model: AppModel) {
        self.id = id
        self.model = model
        self.view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        self.cachedCwd = cwd
        super.init()
        view.autoresizingMask = [.width, .height]

        let proc = LocalProcess(delegate: self)
        process = proc
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        // A pane should look like a freshly opened terminal no matter how amux
        // itself was launched. If amux is started from inside a coding-agent
        // session, that session's markers are inherited here and leak into every
        // pane — an agent then thinks it is a nested child of itself and
        // disables transcript saving. Strip them; the login shell re-sources the
        // user's own profile, so anything they genuinely set comes back.
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") {
            env.removeValue(forKey: key)
        }
        env["AMUX_ENV"] = "1"
        env["AMUX_PANE_ID"] = id
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let envArray = env.map { "\($0.key)=\($0.value)" }
        // leading-dash argv[0] = login shell, so PATH etc. come up like a real terminal
        proc.startProcess(
            executable: shell,
            args: [],
            environment: envArray,
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: cwd)

        // delegate + theme only after the process exists: setting the font
        // triggers an immediate sizeChanged callback
        view.terminalDelegate = self
        applyTheme(TermThemes.effectiveFromDefaults())
    }

    func sendText(_ text: String) {
        guard !exited, let process else { return }
        process.send(data: ArraySlice(Array(text.utf8)))
    }

    func terminate() {
        guard !exited else { return }
        exited = true
        process?.terminate()
    }

    /// Last rows of the visible screen, for agent state detection.
    func screenTail(lines: Int = 18) -> String {
        let term = view.getTerminal()
        var out: [String] = []
        let rows = term.rows
        for row in max(0, rows - lines)..<rows {
            if let line = term.getLine(row: row) {
                out.append(line.translateToString(trimRight: true))
            }
        }
        return out.joined(separator: "\n")
    }

    /// Last known working directory. Non-blocking: refreshed off-thread.
    func currentCwd() -> String? { cachedCwd }

    func applyTheme(_ theme: TermTheme) {
        view.installColors(theme.ansiTerm)
        view.nativeBackgroundColor = theme.bgNS
        view.nativeForegroundColor = theme.fgNS
        view.caretColor = theme.cursorNS
        let size = CGFloat(UserDefaults.standard.object(forKey: "termFontSize") as? Double ?? 13)
        view.font = Fonts.mono(size)
    }
}

extension PaneRuntime: @MainActor TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 1, newRows > 1 else { return }
        cols = UInt16(newCols)
        rows = UInt16(newRows)
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        if let process, process.childfd >= 0 {
            _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
        }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !exited, let process else { return }
        process.send(data: data)
    }

    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

extension PaneRuntime: @MainActor LocalProcessDelegate {
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        guard !exited else { return }
        exited = true
        model?.paneExited(id)
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        lastOutputAt = Date()
        view.feed(byteArray: slice)
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
    }
}

/// Hosts a pane's persistent TerminalView inside SwiftUI, re-parenting as needed.
struct TerminalHost: NSViewRepresentable {
    let paneTerminal: PaneRuntime

    func makeNSView(context: Context) -> NSView { paneTerminal.container }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
