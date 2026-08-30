import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

/// One browser pane = one persistent WKWebView (WebKit, same engine cmux uses).
@MainActor
final class WebPaneRuntime: NSObject, ObservableObject {
    let id: String
    weak var model: AppModel?
    let view: WKWebView

    @Published var url: URL?
    @Published var title: String = "New tab"
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var editingURL = true   // fresh tabs start in the URL field

    init(id: String, url: URL?, model: AppModel) {
        self.id = id
        self.model = model
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        self.view = WKWebView(frame: .zero, configuration: config)
        super.init()
        view.isInspectable = true
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
        if let url {
            self.url = url
            self.editingURL = false
            view.load(URLRequest(url: url))
        }
    }

    func navigate(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var target: URL?
        if trimmed.contains("://") {
            target = URL(string: trimmed)
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            target = URL(string: "https://" + trimmed)
        } else {
            let q = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            target = URL(string: "https://www.google.com/search?q=" + q)
        }
        guard let target else { return }
        editingURL = false
        url = target
        view.load(URLRequest(url: target))
    }

    func reload() { view.reload() }
    func goBack() { view.goBack() }
    func goForward() { view.goForward() }

    var domain: String {
        url?.host ?? ""
    }

    var isSecure: Bool {
        url?.scheme == "https"
    }

    func detach() {
        view.stopLoading()
        view.removeFromSuperview()
    }
}

extension WebPaneRuntime: @MainActor WKNavigationDelegate {
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        url = webView.url
        isLoading = true
        syncState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        url = webView.url
        title = webView.title?.isEmpty == false ? webView.title! : (webView.url?.host ?? "New tab")
        isLoading = false
        syncState()
        model?.webPaneChanged()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    private func syncState() {
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
    }
}


// MARK: - AppKit drop shield
//
// WKWebView is a real NSView registered as a drag destination, and AppKit
// resolves drop targets by hit-testing actual views — a SwiftUI .onDrop overlay
// never wins that contest. So we park a transparent NSView above the web view
// that is invisible to clicks (hitTest returns nil) but becomes the drag
// destination while an in-app pane drag is running.
final class PaneDropShield: NSView {
    nonisolated(unsafe) static var dragActive = false

    var paneId: String = ""
    weak var model: AppModel?
    var onEdge: ((String?) -> Void)?
    /// Panes in background tabs stay mounted; they must not swallow drops.
    var isActive: Bool = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([NSPasteboard.PasteboardType(PaneDrag.typeID)])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        (Self.dragActive && isActive) ? super.hitTest(point) : nil
    }

    private func edge(at point: NSPoint) -> String {
        let fx = point.x / max(bounds.width, 1)
        let fy = point.y / max(bounds.height, 1)
        if fx > 0.3 && fx < 0.7 && fy > 0.3 && fy < 0.7 { return "center" }
        let candidates: [(String, CGFloat)] = [
            ("left", fx), ("right", 1 - fx), ("up", fy), ("down", 1 - fy),
        ]
        return candidates.min { $0.1 < $1.1 }!.0
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onEdge?(edge(at: convert(sender.draggingLocation, from: nil)))
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onEdge?(edge(at: convert(sender.draggingLocation, from: nil)))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onEdge?(nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let e = edge(at: convert(sender.draggingLocation, from: nil))
        onEdge?(nil)
        Self.dragActive = false
        guard let data = sender.draggingPasteboard.data(
                forType: NSPasteboard.PasteboardType(PaneDrag.typeID)),
              let payload = String(data: data, encoding: .utf8),
              let model else { return false }
        let target = paneId
        Task { @MainActor in
            model.endDrag()
            if payload.hasPrefix("pane:") {
                let src = String(payload.dropFirst(5))
                guard src != target else { return }
                if e == "center" { model.swapPanes(src, target) }
                else { model.movePane(src, toEdge: e, of: target) }
            } else if payload.hasPrefix("tab:") {
                model.mergeTab(String(payload.dropFirst(4)),
                               toEdge: e == "center" ? "right" : e, of: target)
            }
        }
        return true
    }
}

/// Hosts the persistent WKWebView, re-parenting across SwiftUI re-renders.
struct WebHost: NSViewRepresentable {
    let runtime: WebPaneRuntime
    let paneId: String
    let model: AppModel
    var isActive: Bool = true
    let onEdge: (String?) -> Void

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if runtime.view.superview !== nsView {
            attach(to: nsView)
        }
        if let shield = nsView.subviews.compactMap({ $0 as? PaneDropShield }).first {
            shield.paneId = paneId
            shield.model = model
            shield.onEdge = onEdge
            shield.isActive = isActive
        }
    }

    private func attach(to container: NSView) {
        let v = runtime.view
        v.removeFromSuperview()
        v.frame = container.bounds
        v.autoresizingMask = [.width, .height]
        container.addSubview(v)

        let shield = PaneDropShield(frame: container.bounds)
        shield.autoresizingMask = [.width, .height]
        shield.paneId = paneId
        shield.model = model
        shield.onEdge = onEdge
        shield.isActive = isActive
        container.addSubview(shield, positioned: .above, relativeTo: v)
    }
}

// MARK: - cmux-style browser toolbar

struct BrowserToolbar: View {
    @ObservedObject var runtime: WebPaneRuntime
    let paneId: String
    let model: AppModel
    let focused: Bool
    @Environment(\.palette) private var pal
    @State private var urlText = ""
    @FocusState private var urlFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(pal.faint2)
                .frame(width: 16, height: 24)
                .contentShape(Rectangle())
                .onDrag {
                    model.beginDrag("pane:\(paneId)")
                    return PaneDrag.provider("pane:\(paneId)")
                }
                .help("Drag to move this browser pane")
            navButton("chevron.left", enabled: runtime.canGoBack) { runtime.goBack() }
            navButton("chevron.right", enabled: runtime.canGoForward) { runtime.goForward() }
            navButton("arrow.clockwise", enabled: true) { runtime.reload() }

            if runtime.editingURL {
                TextField("Search or enter URL", text: $urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(pal.ink)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(pal.bg))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(pal.spot, lineWidth: 2))
                    .focused($urlFocused)
                    .onSubmit { runtime.navigate(urlText) }
                    .onExitCommand {
                        if runtime.url != nil { runtime.editingURL = false }
                    }
                    .onAppear {
                        urlText = runtime.url?.absoluteString ?? ""
                        urlFocused = true
                    }
            } else {
                Button {
                    urlText = runtime.url?.absoluteString ?? ""
                    runtime.editingURL = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: runtime.isSecure ? "lock.fill" : "globe")
                            .font(.system(size: 10))
                            .foregroundStyle(pal.faint)
                        Text(runtime.domain.isEmpty ? "Search or enter URL" : runtime.domain)
                            .font(.system(size: 13))
                            .foregroundStyle(pal.ink)
                            .lineLimit(1)
                        if runtime.isLoading {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(runtime.url?.absoluteString ?? "")
            }

            Spacer(minLength: 4)

            toolButton("wrench.and.screwdriver", "Web Inspector (right-click page → Inspect Element)") {
                // isInspectable is on; the standard path is the context menu.
            }
            toolButton("safari", "Open in default browser") {
                if let url = runtime.url { NSWorkspace.shared.open(url) }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(pal.panel)
        .contentShape(Rectangle())
        .onDrag {
            model.beginDrag("pane:\(paneId)")
            return PaneDrag.provider("pane:\(paneId)")
        }
        .contextMenu {
            Button("Copy URL") {
                if let url = runtime.url {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            Button("Open in default browser") {
                if let url = runtime.url { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Split right") { model.splitPane(paneId, direction: "right") }
            Button("Split down") { model.splitPane(paneId, direction: "down") }
            Button("Zoom") { model.zoomPane(paneId) }
            Divider()
            Button("Close pane", role: .destructive) { model.closePane(paneId) }
        }
    }

    private func navButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? pal.dim : pal.faint2.opacity(0.5))
        .disabled(!enabled)
    }

    private func toolButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(pal.faint)
        .help(help)
    }
}
