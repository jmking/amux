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
/// Hosts the persistent WKWebView, re-parenting across SwiftUI re-renders.
struct WebHost: NSViewRepresentable {
    let runtime: WebPaneRuntime
    let paneId: String
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if runtime.view.superview !== nsView { attach(to: nsView) }
    }

    private func attach(to container: NSView) {
        let v = runtime.view
        v.removeFromSuperview()
        v.frame = container.bounds
        v.autoresizingMask = [.width, .height]
        container.addSubview(v)
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
                } preview: {
                    DragChip(icon: "globe", label: runtime.domain.isEmpty ? "browser" : runtime.domain)
                        .environment(\.palette, pal)
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
            Divider().frame(height: 14).overlay(pal.line2)
            PaneChromeButtons(model: model, paneId: paneId)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(pal.panel)
        .contentShape(Rectangle())
        .onDrag {
            model.beginDrag("pane:\(paneId)")
            return PaneDrag.provider("pane:\(paneId)")
        } preview: {
            DragChip(icon: "globe", label: runtime.domain.isEmpty ? "browser" : runtime.domain)
                .environment(\.palette, pal)
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
