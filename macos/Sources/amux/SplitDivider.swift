import AppKit

/// The divider between two panes, as an AppKit view rather than a SwiftUI one.
///
/// Two things SwiftUI could not give a divider: a cursor that survives its own
/// re-renders, and drag events that keep arriving after the pointer has left
/// the strip. A cursor rect is re-asserted by AppKit every time the window's
/// cursor rects are rebuilt, where an `NSCursor.set()` from `onHover` was undone
/// by the very view update the drag caused, so the pointer flickered between
/// the arrow and the resize cursor on every mouse move. And AppKit routes
/// `mouseDragged` / `mouseUp` to the view that took `mouseDown` wherever the
/// pointer goes, so a fast drag cannot outrun a 7pt strip.
@MainActor
final class SplitDividerNSView: NSView {
    var horizontal = true {
        didSet {
            if oldValue != horizontal {
                window?.invalidateCursorRects(for: self)
                needsDisplay = true
            }
        }
    }
    /// The ratio the divider is laid out at right now, live or stored.
    var ratio = 0.5
    /// The parent's extent along the drag axis, minus the gap, in points.
    var span: CGFloat = 1
    /// Where the gap sits inside this view along the drag axis: the hit strip
    /// reaches `slopA` past the gap into the leading (left or top) neighbour.
    var slopA: CGFloat = 0 { didSet { if oldValue != slopA { needsDisplay = true } } }
    var gap: CGFloat = 7 { didSet { if oldValue != gap { needsDisplay = true } } }
    /// The bar shown while hovering or dragging; fed from the palette.
    var highlight: NSColor = .controlAccentColor { didSet { if lit { needsDisplay = true } } }
    var onBegin: (() -> Void)?
    var onDrag: ((Double) -> Void)?
    /// nil: a click that never moved, or a divider torn down mid-drag.
    var onEnd: ((Double?) -> Void)?
    /// A press that never moved, in this view's top-left coordinates. The hit
    /// strip reaches over the neighbouring panes' padding, and a click there
    /// should still land on the pane.
    var onClick: ((CGPoint) -> Void)?

    private var down: NSPoint?
    /// Ratio this drag started from. Mouse deltas are measured from the press,
    /// not from wherever the divider has since been laid out: measuring from a
    /// rect that has already moved adds the whole delta to an already-moved
    /// divider and runs away to the clamp.
    private var base = 0.5
    private var lastDragged: Double?
    /// Past the movement threshold: a press that twitches a pixel is a click.
    private var dragging = false
    private var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }
    private var keyObservers: [NSObjectProtocol] = []
    private var cursor: NSCursor { horizontal ? .resizeLeftRight : .resizeUpDown }
    private var lit: Bool { hovering || down != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // .inVisibleRect: the area follows the view, which the layout moves on
        // every frame of a drag.
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        for o in keyObservers { NotificationCenter.default.removeObserver(o) }
    }

    /// Top-left, like the layout that places this view, so the bar's maths
    /// reads the same way as DividerPlacement.hitRect.
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    // MARK: drawing

    /// A 2pt bar centred on the gap, only while hovered or dragged: the rest
    /// of the time the divider is invisible and the cursor is the affordance.
    override func draw(_ dirtyRect: NSRect) {
        guard lit else { return }
        let bar = horizontal
            ? NSRect(x: slopA + gap / 2 - 1, y: 0, width: 2, height: bounds.height)
            : NSRect(x: 0, y: slopA + gap / 2 - 1, width: bounds.width, height: 2)
        highlight.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    // MARK: the drag

    override func mouseDown(with event: NSEvent) {
        // A press while a drag is still open means its mouse-up was swallowed
        // (an app-modal alert opened mid-drag). Close it at the ratio the panes
        // are drawn at, so nothing moves, then start afresh.
        if down != nil {
            let r = lastDragged
            finish()
            onEnd?(r)
        }
        down = event.locationInWindow
        base = ratio
        lastDragged = nil
        dragging = false
        // While the button is down nothing else may touch the cursor: the pane
        // beside the strip has an I-beam rect of its own, and SwiftUI rebuilds
        // the window's rects on every layout the drag produces. Dividers are
        // the only thing in this app that pauses them, so whichever divider
        // finishes re-enables them for the window (see finish).
        window?.disableCursorRects()
        cursor.set()
        needsDisplay = true
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down, span > 0 else { return }
        let p = event.locationInWindow
        if !dragging {
            // AppKit reports sub-point motion between a press and its release;
            // a resize starts once the pointer has clearly moved.
            guard (horizontal ? abs(p.x - down.x) : abs(p.y - down.y)) >= 2 else { return }
            dragging = true
        }
        cursor.set()
        let r = ratio(at: p, from: down)
        lastDragged = r
        onDrag?(r)
    }

    override func mouseUp(with event: NSEvent) {
        guard let down else { return }
        // Commit the ratio the layout already shows, not one recomputed at the
        // mouse-up point: the stored ratio then reproduces the last live rects
        // exactly and release moves nothing.
        let r = lastDragged
        let pressed = convert(down, from: nil)
        finish()
        onEnd?(r)
        if r == nil { onClick?(pressed) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in keyObservers { NotificationCenter.default.removeObserver(o) }
        keyObservers.removeAll()
        guard let w = window else { return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: w, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleHealCheck(attempt: 0) }
            })
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, down != nil {
            // Torn down mid-drag (a workspace switch, a split that collapsed):
            // nothing to commit, the split this was dragging may no longer be
            // at this path. The layout is mid-update, so the callback waits a
            // turn rather than writing view state from inside it.
            finish()
            let end = onEnd
            DispatchQueue.main.async { end?(nil) }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// A drag whose mouse-up was swallowed (an app-modal alert, a panel) would
    /// leave the layout stream open and the window's cursor rects off. Still
    /// thinking we are dragging while no button is down is the tell; the
    /// window changing key is when it can have happened. Checked a beat later
    /// and then only once the button is up: the click that takes the app away
    /// holds it down, a quick click from an inactive app can have its mouseUp
    /// still queued, and Cmd-Tab mid-drag resigns key with the button held
    /// while that drag carries on.
    private func scheduleHealCheck(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.down != nil else { return }
                if NSEvent.pressedMouseButtons & 1 != 0 {
                    if attempt < 40 { self.scheduleHealCheck(attempt: attempt + 1) }
                    return
                }
                let r = self.lastDragged
                self.finish()
                self.onEnd?(r)
            }
        }
    }

    private func ratio(at p: NSPoint, from down: NSPoint) -> Double {
        // Window y grows upward and the layout's y grows downward, so dragging
        // down (smaller window y) grows child a.
        let delta = horizontal ? p.x - down.x : down.y - p.y
        return min(0.9, max(0.1, base + Double(delta / span)))
    }

    private func finish() {
        down = nil
        dragging = false
        if let w = window, !w.areCursorRectsEnabled {
            w.enableCursorRects()
            w.resetCursorRects()
        }
        // AppKit sends no enter/exit while the button is down, so where the
        // pointer ended up has to be asked for.
        if let w = window {
            hovering = bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil))
        }
        needsDisplay = true
    }
}
