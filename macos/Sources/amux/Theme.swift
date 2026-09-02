import SwiftUI
import AppKit
import SwiftTerm

// MARK: - design tokens

struct Palette {
    let bg: SwiftUI.Color
    let panel: SwiftUI.Color
    let mass: SwiftUI.Color
    let ink: SwiftUI.Color
    let dim: SwiftUI.Color
    let faint: SwiftUI.Color
    let faint2: SwiftUI.Color
    let line: SwiftUI.Color
    let line2: SwiftUI.Color
    let spot: SwiftUI.Color
    let spotInk: SwiftUI.Color

    // Soft charcoal rather than near-black, so panels read as raised surfaces
    // instead of holes. Colour is spent almost entirely on the state dots: the
    // accent is desaturated and only marks selection.
    static let darkMode = Palette(
        bg: SwiftUI.Color(hex: 0x18181a), panel: SwiftUI.Color(hex: 0x232326), mass: SwiftUI.Color(hex: 0x313137),
        ink: SwiftUI.Color(hex: 0xf0f0f2), dim: SwiftUI.Color(hex: 0xd2d2d8), faint: SwiftUI.Color(hex: 0x9a9aa3),
        faint2: SwiftUI.Color(hex: 0x7a7a83), line: SwiftUI.Color(hex: 0x2a2a2e), line2: SwiftUI.Color(hex: 0x3a3a41),
        spot: SwiftUI.Color(hex: 0x6dbfae), spotInk: SwiftUI.Color(hex: 0x18181a))

    // The same restraint in reverse: warm-neutral greys, no colour cast.
    static let lightMode = Palette(
        bg: SwiftUI.Color(hex: 0xfafafb), panel: SwiftUI.Color(hex: 0xf1f1f3), mass: SwiftUI.Color(hex: 0xe5e5e9),
        ink: SwiftUI.Color(hex: 0x1c1d20), dim: SwiftUI.Color(hex: 0x3f4145), faint: SwiftUI.Color(hex: 0x6e7176),
        faint2: SwiftUI.Color(hex: 0x94979c), line: SwiftUI.Color(hex: 0xe8e8eb), line2: SwiftUI.Color(hex: 0xdadade),
        spot: SwiftUI.Color(nsColor: .controlAccentColor), spotInk: .white)

    /// Corner radii. Rounder than typical AppKit chrome: the rows read as soft
    /// cards rather than list cells.
    enum Radius {
        static let row: CGFloat = 8
        static let card: CGFloat = 12
        static let chip: CGFloat = 6
    }
}

enum AgentStateColor {
    static func color(_ state: String, light: Bool = false) -> SwiftUI.Color {
        switch state {
        case "working": return SwiftUI.Color(hex: light ? 0xb5811c : 0xd9ad4a)
        case "idle": return SwiftUI.Color(hex: light ? 0x358f56 : 0x6dba82)
        case "blocked": return SwiftUI.Color(hex: light ? 0xc2493c : 0xd4635d)
        case "done": return SwiftUI.Color(hex: light ? 0x2a8f86 : 0x8fd9cd)
        default: return SwiftUI.Color(hex: light ? 0x909398 : 0x86868f)
        }
    }
}

extension SwiftUI.Color {
    init(hex: Int) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1)
    }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1)
    }
    var termColor: SwiftTerm.Color {
        let c = usingColorSpace(.sRGB) ?? self
        return SwiftTerm.Color(
            red: UInt16(c.redComponent * 65535),
            green: UInt16(c.greenComponent * 65535),
            blue: UInt16(c.blueComponent * 65535))
    }
}

// MARK: - Terminal themes

struct TermTheme: Identifiable {
    let name: String
    let bg: Int
    let fg: Int
    let cursor: Int
    let ansi: [Int]   // 16 colors
    var id: String { name }

    var bgNS: NSColor { NSColor(hex: bg) }
    var fgNS: NSColor { NSColor(hex: fg) }
    var cursorNS: NSColor { NSColor(hex: cursor) }
    var ansiTerm: [SwiftTerm.Color] { ansi.map { NSColor(hex: $0).termColor } }
}

enum TermThemes {
    static let all: [TermTheme] = [
        TermTheme(name: "amux", bg: 0x141414, fg: 0xd0d0d0, cursor: 0x73daca, ansi: [
            0x1a1d22, 0xe06c75, 0x8ecf7a, 0xe6c060, 0x7aa2f7, 0xcba6f7, 0x94e2d5, 0xc8cdd4,
            0x5a6068, 0xff7a85, 0x7ecf8a, 0xf0d080, 0x8fb5ff, 0xdbc0ff, 0xaef0e4, 0xe8ecf2]),
        TermTheme(name: "amux-light", bg: 0xffffff, fg: 0x1f2328, cursor: 0x0f9b8e, ansi: [
            0x24292f, 0xcf222e, 0x1a7f37, 0x9a6700, 0x0969da, 0x8250df, 0x1b7c83, 0x6e7781,
            0x57606a, 0xa40e26, 0x116329, 0x7d4e00, 0x0550ae, 0x6639ba, 0x0f766e, 0x24292f]),
        TermTheme(name: "catppuccin", bg: 0x1e1e2e, fg: 0xcdd6f4, cursor: 0xf5e0dc, ansi: [
            0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xcba6f7, 0x94e2d5, 0xbac2de,
            0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xcba6f7, 0x94e2d5, 0xa6adc8]),
        TermTheme(name: "catppuccin-latte", bg: 0xeff1f5, fg: 0x4c4f69, cursor: 0x8839ef, ansi: [
            0x5c5f77, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0x8839ef, 0x179299, 0xacb0be,
            0x6c6f85, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0x8839ef, 0x179299, 0xbcc0cc]),
        TermTheme(name: "tokyo-night", bg: 0x1a1b26, fg: 0xc0caf5, cursor: 0xc0caf5, ansi: [
            0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
            0x414868, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5]),
        TermTheme(name: "dracula", bg: 0x282a36, fg: 0xf8f8f2, cursor: 0xf8f8f2, ansi: [
            0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
            0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff]),
        TermTheme(name: "nord", bg: 0x2e3440, fg: 0xd8dee9, cursor: 0xd8dee9, ansi: [
            0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
            0x4c566a, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x8fbcbb, 0xeceff4]),
        TermTheme(name: "gruvbox", bg: 0x282828, fg: 0xebdbb2, cursor: 0xebdbb2, ansi: [
            0x282828, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0xa89984,
            0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f, 0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2]),
        TermTheme(name: "one-dark", bg: 0x282c34, fg: 0xabb2bf, cursor: 0x528bff, ansi: [
            0x282c34, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xabb2bf,
            0x5c6370, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xffffff]),
        TermTheme(name: "rose-pine", bg: 0x191724, fg: 0xe0def4, cursor: 0xe0def4, ansi: [
            0x26233a, 0xeb6f92, 0x31748f, 0xf6c177, 0x9ccfd8, 0xc4a7e7, 0xebbcba, 0xe0def4,
            0x6e6a86, 0xeb6f92, 0x31748f, 0xf6c177, 0x9ccfd8, 0xc4a7e7, 0xebbcba, 0xe0def4]),
        TermTheme(name: "vesper", bg: 0x101010, fg: 0xc1c1c1, cursor: 0xffcfa8, ansi: [
            0x101010, 0xf5a191, 0x90b99f, 0xe6b99d, 0xaca1cf, 0xe29eca, 0xea83a5, 0xc1c1c1,
            0x7e7e7e, 0xff8080, 0x99ffe4, 0xffc799, 0xb9aeda, 0xecaad6, 0xf591b2, 0xffffff]),
    ]

    static func named(_ name: String) -> TermTheme {
        all.first { $0.name == name } ?? all[0]
    }

    /// The default dark theme swaps for latte in paper mode, like the web client.
    static func effective(_ name: String, mode: String) -> TermTheme {
        // the default theme has a dark and a light twin; explicit picks are kept
        if mode == "light" && name == "amux" { return named("amux-light") }
        if mode == "dark" && name == "amux-light" { return named("amux") }
        return named(name)
    }

    static func effectiveFromDefaults() -> TermTheme {
        effective(
            UserDefaults.standard.string(forKey: "termTheme") ?? "amux",
            mode: UserDefaults.standard.string(forKey: "mode") ?? "dark")
    }
}

// MARK: - Agent brand chips
// Distinct identity chips per agent kind (color + glyph). Deliberately not the
// vendors' trademarked logos — recognizable stand-ins in each brand's color.

struct AgentBrand {
    let color: Int
    let glyph: String

    static let map: [String: AgentBrand] = [
        "claude": AgentBrand(color: 0xD97757, glyph: "✳"),
        "codex": AgentBrand(color: 0x10a37f, glyph: "◎"),
        "rovo": AgentBrand(color: 0x1868db, glyph: "◆"),
    ]

    static func of(_ kind: String) -> AgentBrand {
        map[kind] ?? AgentBrand(color: 0x908f96, glyph: String(kind.prefix(1)))
    }
}

struct AgentChip: View {
    let kind: String
    var size: CGFloat = 16

    private static var iconCache: [String: NSImage?] = [:]

    /// Locate an agent icon by walking real paths rather than `Bundle.module`.
    /// SwiftPM builds the resource bundle WITHOUT an Info.plist, so `Bundle(url:)`
    /// refuses it and `Bundle.module` traps — which crashed the app the moment
    /// any agent chip rendered.
    private static func iconURL(_ kind: String) -> URL? {
        let file = kind + ".png"
        var dirs: [URL] = []
        if let res = Bundle.main.resourceURL {
            dirs.append(res.appendingPathComponent("agent-icons"))
            dirs.append(res.appendingPathComponent("amux_amux.bundle/agent-icons"))
        }
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            dirs.append(exeDir.appendingPathComponent("amux_amux.bundle/agent-icons"))
            dirs.append(exeDir.appendingPathComponent("agent-icons"))
        }
        for dir in dirs {
            let candidate = dir.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func icon(for kind: String) -> NSImage? {
        if let cached = iconCache[kind] { return cached }
        let image = iconURL(kind).flatMap { NSImage(contentsOf: $0) }
        iconCache[kind] = image     // nil is cached too: fall back to the glyph chip
        return image
    }

    /// Marks that ship as a single-colour glyph get tinted to the current
    /// palette so they read on both ink and paper; colour marks are left alone.
    private static let monochrome: Set<String> = ["codex"]

    var body: some View {
        if let icon = Self.icon(for: kind) {
            Image(nsImage: icon)
                .resizable()
                .renderingMode(Self.monochrome.contains(kind) ? .template : .original)
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityLabel(kind)
        } else {
            let brand = AgentBrand.of(kind)
            Text(brand.glyph)
                .font(.system(size: size * 0.55, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: Palette.Radius.chip).fill(SwiftUI.Color(hex: brand.color)))
                .accessibilityLabel(kind)
        }
    }
}

// MARK: - Fonts

enum Fonts {
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont(name: "JetBrainsMono-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
    // cmux chrome: SF Pro for UI, mono only inside terminals
    static let uiMono = Font.system(size: 13)
    static let uiMonoSmall = Font.system(size: 11)
    static let uiMonoTiny = Font.system(size: 10)
}

// MARK: - Environment plumbing for the active palette

struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.darkMode
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
