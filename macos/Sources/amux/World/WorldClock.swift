import RealityKit
import AppKit
import simd

// MARK: - The wall clock
//
// A red seven-segment display in a black bezel, the kind that hangs in a
// workshop. The digits are drawn with CoreGraphics into a small texture and
// redrawn only when the minute changes; the face is unlit so it reads the
// same at noon and at midnight.

@MainActor
final class WorldClock {
    let entity = Entity()
    private let face: ModelEntity
    private var shownMinute = -1
    private var drawing = false

    private static let width: Float = 1.0
    private static let height: Float = 0.42

    init() {
        let bezel = WorldPrimitives.box(SIMD3(Self.width, Self.height, 0.06), NSColor(white: 0.04, alpha: 1), roughness: 0.6, corner: 0.02)
        bezel.position = SIMD3(0, 0, 0)
        entity.addChild(bezel)
        var m = UnlitMaterial(color: .black)
        face = ModelEntity(mesh: .generatePlane(width: Self.width - 0.06, height: Self.height - 0.06), materials: [m])
        face.position = SIMD3(0, 0, 0.031)
        entity.addChild(face)
        m.color = .init(tint: .black)
    }

    /// Redraws the face if the minute has changed.
    func update(hour: Float) {
        let h = ((hour.truncatingRemainder(dividingBy: 24)) + 24).truncatingRemainder(dividingBy: 24)
        let minute = Int(h * 60) % (24 * 60)
        guard minute != shownMinute, !drawing else { return }
        drawing = true
        shownMinute = minute
        Task { [weak self] in
            defer { self?.drawing = false }
            guard let img = Self.draw(hh: minute / 60, mm: minute % 60),
                  let tex = try? await TextureResource(image: img, options: .init(semantic: .color)) else { return }
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(tex))
            self?.face.model?.materials = [m]
        }
    }

    // segments a..g as (x, y, w, h) in a 100 x 180 digit box, bars 22 thick
    private static let segments: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (14, 158, 72, 22),   // a  top
        (78, 94, 22, 72),    // b  upper right
        (78, 14, 22, 72),    // c  lower right
        (14, 0, 72, 22),     // d  bottom
        (0, 14, 22, 72),     // e  lower left
        (0, 94, 22, 72),     // f  upper left
        (14, 79, 72, 22),    // g  middle
    ]
    private static let glyphs: [[Int]] = [
        [0, 1, 2, 3, 4, 5], [1, 2], [0, 1, 6, 4, 3], [0, 1, 6, 2, 3], [5, 6, 1, 2],
        [0, 5, 6, 2, 3], [0, 5, 6, 4, 2, 3], [0, 1, 2], [0, 1, 2, 3, 4, 5, 6], [0, 1, 2, 3, 5, 6],
    ]

    private static func draw(hh: Int, mm: Int) -> CGImage? {
        let W = 640, H = 270
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.03, green: 0.02, blue: 0.02, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let lit = CGColor(red: 1.0, green: 0.16, blue: 0.08, alpha: 1)
        let dim = CGColor(red: 0.16, green: 0.04, blue: 0.03, alpha: 1)
        let digitW: CGFloat = 100, digitH: CGFloat = 180, gap: CGFloat = 34, colonW: CGFloat = 40
        let total = digitW * 4 + gap * 3 + colonW + gap
        var x = (CGFloat(W) - total) / 2
        let y = (CGFloat(H) - digitH) / 2
        // a little glow behind the lit segments
        ctx.setShadow(offset: .zero, blur: 14, color: CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 0.7))
        func digit(_ d: Int) {
            let on = Set(glyphs[d])
            for (i, s) in segments.enumerated() {
                ctx.setFillColor(on.contains(i) ? lit : dim)
                let r = CGRect(x: x + s.0, y: y + s.1, width: s.2, height: s.3)
                ctx.fill(r)
            }
            x += digitW + gap
        }
        digit(hh / 10); digit(hh % 10)
        ctx.setFillColor(lit)
        ctx.fill(CGRect(x: x + 9, y: y + 48, width: 22, height: 22))
        ctx.fill(CGRect(x: x + 9, y: y + 112, width: 22, height: 22))
        x += colonW + gap
        digit(mm / 10); digit(mm % 10)
        return ctx.makeImage()
    }
}
