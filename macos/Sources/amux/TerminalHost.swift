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
        let c = TerminalContainerView()
        view.frame = c.bounds
        view.autoresizingMask = [.width, .height]
        c.addSubview(view)
        c.onAttach = { [weak self] in self?.claimKeyIfFocused() }
        return c
    }()

    /// A new tab's view is not in the window yet when the model asks it to
    /// become key (followFocus runs before SwiftUI mounts it), and hiding the
    /// tab it replaces hands first responder to whatever AppKit picks next. So
    /// the view asks for it itself the moment it lands in a window.
    func claimKeyIfFocused() {
        guard let model, model.focusedWorkspace?.focusedPaneId == id,
              model.activeSheet == nil, !model.paletteOpen,
              let w = view.window, w.firstResponder !== view else { return }
        w.makeFirstResponder(view)
    }
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
    private var winSizeFlush: Task<Void, Never>?
    /// A size the view has taken that the pty has not been told about yet.
    private var pendingWinSize = false
    /// The last size the pty was told, starting with what it was spawned at.
    private var lastSent: (cols: UInt16, rows: UInt16)?

    var shellPid: pid_t { process?.shellPid ?? 0 }

    init(id: String, cwd: String, model: AppModel) {
        self.id = id
        self.model = model
        self.view = AmuxTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
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
        lastSent = (cols, rows)   // getWindowSize() below is what it was spawned with

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
        winSizeFlush?.cancel()
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
        let changed = cols != UInt16(newCols) || rows != UInt16(newRows)
        cols = UInt16(newCols)
        rows = UInt16(newRows)
        guard changed else { return }
        if (model?.layoutStreams ?? 0) > 0 {
            // Mid-stream (a divider drag, a window live resize, an animated
            // relayout) the view has already reflowed; the shell redraws its
            // prompt on every SIGWINCH, which is how one drag used to stack
            // prompt after prompt in the pane. The kernel hears once, when the
            // stream ends. The timer is a backstop for a stream whose end never
            // comes: it waits while a button is held, so a pause mid-drag is
            // not a SIGWINCH, and gives up after a long quiet.
            pendingWinSize = true
            armTrailingFlush()
        } else {
            // One discrete step: a split, zoom, close, font change, first layout.
            flushWinSize()
        }
    }

    /// Called by the model when the last open layout stream closes.
    func flushPendingWinSize() {
        if pendingWinSize { flushWinSize() }
    }

    private func armTrailingFlush() {
        winSizeFlush?.cancel()
        winSizeFlush = Task { @MainActor [weak self] in
            var waited = 0
            while true {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                waited += 1
                // A stream with the primary button still down is a divider drag
                // or a window live resize that has paused; its end (mouseUp,
                // didEndLiveResize) is still coming, so keep waiting. A stream
                // with the button up is the one whose end never came.
                if (self.model?.layoutStreams ?? 0) > 0, NSEvent.pressedMouseButtons & 1 != 0, waited < 40 {
                    continue
                }
                self.winSizeFlush = nil
                self.flushWinSize()
                return
            }
        }
    }

    private func flushWinSize() {
        winSizeFlush?.cancel()
        winSizeFlush = nil
        pendingWinSize = false
        guard !exited, let p = process, p.childfd >= 0 else { return }
        if let last = lastSent, last.cols == cols, last.rows == rows { return }
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: p.childfd, windowSize: &size)
        lastSent = (cols, rows)
        if AmuxTerminalView.trace {
            FileHandle.standardError.write("amux: winsize \(id) \(cols)x\(rows)\n".data(using: .utf8)!)
        }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !exited, let process else { return }
        process.send(data: data)
        // a carriage return is the user sending something to whatever is running
        // here; the agent world uses it to make the figure look up
        if data.contains(0x0D) { model?.noteUserInput(id) }
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

/// The NSView SwiftUI hosts for a terminal; reports landing in a window.
final class TerminalContainerView: NSView {
    var onAttach: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAttach?() }
    }
}

/// SwiftTerm's view with a resize trace behind `AMUX_RESIZE_TRACE=1`: a live
/// drag asks it to reflow and redraw on every frame, and this is how we know
/// what that costs on a real layout without being able to watch the screen.
final class AmuxTerminalView: TerminalView {
    static let trace = ProcessInfo.processInfo.environment["AMUX_RESIZE_TRACE"] != nil

    override func setFrameSize(_ newSize: NSSize) {
        guard Self.trace else { super.setFrameSize(newSize); return }
        let t0 = CFAbsoluteTimeGetCurrent()
        super.setFrameSize(newSize)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if ms > 4 {
            FileHandle.standardError.write(
                "amux: terminal resize \(Int(newSize.width))x\(Int(newSize.height)) \(String(format: "%.1f", ms))ms\n"
                    .data(using: .utf8)!)
        }
    }
}

/// Hosts a pane's persistent TerminalView inside SwiftUI, re-parenting as needed.
struct TerminalHost: NSViewRepresentable {
    let paneTerminal: PaneRuntime
    /// Background tabs stay mounted at SwiftUI opacity 0, which AppKit still
    /// draws: every frame of a divider drag reflowed and fully repainted each
    /// hidden terminal. isHidden is what skips the draw; the frame, and so the
    /// pty size, still follows the card, because hidden views autoresize.
    var isActive: Bool = true

    func makeNSView(context: Context) -> NSView { paneTerminal.container }

    func updateNSView(_ nsView: NSView, context: Context) {
        let v = paneTerminal.view
        if v.isHidden == isActive {
            v.isHidden = !isActive
            // frames it never displayed left nothing on its layer
            if isActive { v.needsDisplay = true }
        }
    }
}
