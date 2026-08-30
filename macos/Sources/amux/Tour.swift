import SwiftUI

// MARK: - Anchors reported by interface regions

enum TourAnchor: Hashable {
    case brand, spaces, agents, tabBar, paneHeader, bell
}

struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourAnchor: Anchor<CGRect>],
                       nextValue: () -> [TourAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func tourAnchor(_ anchor: TourAnchor) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [anchor: $0] }
    }
}

// MARK: - Steps

struct TourStep {
    let anchor: TourAnchor?
    let title: String
    let body: String
}

enum TourScript {
    static let steps: [TourStep] = [
        TourStep(anchor: nil, title: "welcome to amux",
                 body: "amux is a home your coding agents live in. Terminals run inside the app: close the window and everything keeps going (amux stays in the menu bar as ❯a); quitting the app stops every agent. This tour shows you around; use ← → or click Next."),
        TourStep(anchor: .spaces, title: "spaces",
                 body: "A space is a project or task — a directory, usually a branch. Each shows its git branch, dirty count (✚), and ahead marker (↑). Click to switch; right-click for rename, worktrees, and closing. The dot shows the most urgent agent state inside.\n\nParallel work on one repo? Right-click → “New worktree from here…” gives each agent an isolated checkout."),
        TourStep(anchor: .agents, title: "agents — your attention inbox",
                 body: "Every agent found in a pane is tracked here.\n\n● amber pulse = working — ignore it\n● red pulse = blocked, needs an answer — click to jump\n● teal = done: finished while you weren't looking\n○ green = idle, ready for input\n\n“done” clears the moment you focus its tab — like marking a message read. Toggle grouped ↔ priority to sort by who needs you first."),
        TourStep(anchor: .tabBar, title: "tabs",
                 body: "Tabs are views inside a space — “agents”, “server”, “logs”. Double-click to rename, drag to reorder, middle area shows a ZOOM flag when a pane is maximized. ⌘1–9 switches tabs, ⇧⌘[ and ⇧⌘] step through them."),
        TourStep(anchor: .paneHeader, title: "panes",
                 body: "Each pane is a real terminal that survives detach. Hover the header for its toolbar: run a command, start an agent, split right (⌘D), split down (⇧⌘D), zoom (⇧⌘E), close. Right-click for more, including sending Esc or Ctrl+C to a stuck program. ⌥⌘arrows move focus between panes."),
        TourStep(anchor: .paneHeader, title: "drag panes around",
                 body: "Grab a pane by its header and drag:\n\n• onto the left / right / top / bottom edge of another pane → snaps in as a split on that side\n• onto the middle of another pane → swaps the two\n• onto a tab → moves it into that tab\n• onto a space in the sidebar → moves it there as a new tab"),
        TourStep(anchor: .bell, title: "notifications",
                 body: "When an agent finishes or gets stuck in a tab you're not looking at, you get a toast here and in Notification Center. Click any notification to jump straight to the pane — which also marks it seen. ⇧⌘O opens the most recent one."),
        TourStep(anchor: nil, title: "drive it your way",
                 body: "Everything has three routes: click it, use the menus, or press ⌘K for the command palette — type to jump to any space, tab, or agent, or fire any action.\n\nThe habit that makes amux worth it: give an agent work, then leave. The dots will call you back.\n\nReplay this tour any time from Help → Welcome Tour."),
    ]
}

// MARK: - Overlay

struct TourOverlay: View {
    @ObservedObject var model: AppModel
    let anchors: [TourAnchor: Anchor<CGRect>]
    let proxy: GeometryProxy
    @Environment(\.palette) private var pal

    var body: some View {
        if let step = model.tourStep, step < TourScript.steps.count {
            let s = TourScript.steps[step]
            let target: CGRect? = s.anchor.flatMap { anchors[$0].map { proxy[$0] } }
            ZStack {
                scrim(cutout: target)
                    .onTapGesture { } // swallow clicks
                if let r = target {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(pal.spot, lineWidth: 2)
                        .frame(width: r.width + 12, height: r.height + 12)
                        .position(x: r.midX, y: r.midY)
                        .shadow(color: pal.spot.opacity(0.5), radius: 8)
                }
                card(for: s, step: step, target: target)
            }
            .transition(.opacity)
        }
    }

    private func scrim(cutout: CGRect?) -> some View {
        Canvas { ctx, size in
            var path = Path(CGRect(origin: .zero, size: size))
            if let r = cutout {
                path.addRoundedRect(in: r.insetBy(dx: -6, dy: -6), cornerSize: CGSize(width: 8, height: 8))
            }
            ctx.fill(path, with: .color(.black.opacity(0.62)), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(true)
    }

    private func card(for s: TourStep, step: Int, target: CGRect?) -> some View {
        let size = proxy.size
        let cardWidth: CGFloat = 400
        var pos = CGPoint(x: size.width / 2, y: size.height / 2)
        if let r = target {
            let below = r.maxY + 150
            let x = min(max(cardWidth / 2 + 16, r.midX), size.width - cardWidth / 2 - 16)
            if below < size.height - 140 {
                pos = CGPoint(x: x, y: below)
            } else {
                pos = CGPoint(x: x, y: max(140, r.minY - 150))
            }
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text("—").foregroundStyle(pal.spot)
                Text(s.title.uppercased()).tracking(2)
            }
            .font(Fonts.uiMonoSmall)
            .foregroundStyle(pal.faint2)
            Text(s.body)
                .font(.system(size: 12.5))
                .foregroundStyle(pal.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                ForEach(0..<TourScript.steps.count, id: \.self) { i in
                    Circle()
                        .fill(i == step ? pal.spot : pal.line2)
                        .frame(width: 5, height: 5)
                }
                Spacer()
                Button("skip") { model.tourStep = nil; UserDefaults.standard.set(true, forKey: "tourSeen") }
                    .buttonStyle(.plain)
                    .font(Fonts.uiMonoSmall)
                    .foregroundStyle(pal.faint2)
                if step > 0 {
                    Button("back") { model.tourStep = step - 1 }
                        .buttonStyle(.plain)
                        .font(Fonts.uiMono)
                        .foregroundStyle(pal.faint)
                }
                Button(step == TourScript.steps.count - 1 ? "done" : "next") {
                    if step == TourScript.steps.count - 1 {
                        model.tourStep = nil
                        UserDefaults.standard.set(true, forKey: "tourSeen")
                    } else {
                        model.tourStep = step + 1
                    }
                }
                .buttonStyle(.plain)
                .font(Fonts.uiMono.weight(.bold))
                .foregroundStyle(pal.spotInk)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 4).fill(pal.spot))
            }
        }
        .padding(16)
        .frame(width: cardWidth)
        .background(pal.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(pal.line2))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        .position(pos)
        .onKeyPress(.rightArrow) {
            if step < TourScript.steps.count - 1 { model.tourStep = step + 1 }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            if step > 0 { model.tourStep = step - 1 }
            return .handled
        }
        .onKeyPress(.escape) {
            model.tourStep = nil
            UserDefaults.standard.set(true, forKey: "tourSeen")
            return .handled
        }
    }
}
