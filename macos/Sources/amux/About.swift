import SwiftUI
import AppKit

let amuxRepoURL = URL(string: "https://github.com/jmking/amux")!

struct AboutView: View {
    @Environment(\.palette) private var pal

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable().frame(width: 88, height: 88)
            }
            VStack(spacing: 4) {
                Text("amux")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(pal.ink)
                Text(version)
                    .font(.system(size: 11))
                    .foregroundStyle(pal.faint2)
            }
            Text("A native macOS workspace manager for AI coding agents.")
                .font(.system(size: 12))
                .foregroundStyle(pal.faint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                NSWorkspace.shared.open(amuxRepoURL)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text("View on GitHub").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(pal.spotInk)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(pal.spot))
            }
            .buttonStyle(.plain)
            .help(amuxRepoURL.absoluteString)

            Text("Agent marks are trademarks of their respective owners,\nused to identify which agent is running.")
                .font(.system(size: 9.5))
                .foregroundStyle(pal.faint2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28).padding(.vertical, 26)
        .frame(width: 320)
        .background(pal.bg)
    }
}

/// About lives in its own small panel rather than the stock about box, so it can
/// carry a link straight to the repository.
@MainActor
final class AboutWindow {
    static let shared = AboutWindow()
    private var window: NSWindow?

    func show(mode: String) {
        if window == nil {
            let host = NSHostingController(
                rootView: AboutView().environment(\.palette, mode == "light" ? .lightMode : .darkMode))
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 430),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.contentViewController = host
            w.title = "About amux"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            // size to the SwiftUI content, then centre — without an explicit
            // size the hosting controller can report zero and the window is
            // created invisible
            w.setContentSize(host.view.fittingSize == .zero
                             ? NSSize(width: 320, height: 430)
                             : host.view.fittingSize)
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}
