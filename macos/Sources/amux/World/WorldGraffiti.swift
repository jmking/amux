import RealityKit
import AppKit
import simd

// MARK: - Spray paint
//
// A tag drawn with CoreGraphics onto a quad: a marker-style face, a dark
// outline, a soft overspray halo, a few drips off the letters and speckle
// around them, the whole thing leaning a little. Deterministic for a given
// seed so the yard looks the same every launch.

enum WorldGraffiti {
    private static let fontNames = ["Marker Felt Wide", "Chalkduster", "Bradley Hand Bold", "Noteworthy-Bold"]

    /// A tag `height` metres tall, bottom-centre at the origin, facing +z.
    @MainActor
    static func make(_ text: String, color: NSColor, height: Float, seed: UInt64 = 1) async -> ModelEntity? {
        guard !text.isEmpty, let (image, aspect) = draw(text, color: color, seed: seed),
              let tex = try? await TextureResource(image: image, options: .init(semantic: .color)) else { return nil }
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(tex))
        m.blending = .transparent(opacity: 1.0)
        m.opacityThreshold = 0
        let w = height * aspect
        let e = ModelEntity(mesh: .generatePlane(width: w, height: height), materials: [m])
        e.position.y = height / 2
        return e
    }

    private static func draw(_ text: String, color: NSColor, seed: UInt64) -> (CGImage, Float)? {
        var rng = SplitMix(seed: seed)
        let size: CGFloat = 120
        let font = fontNames.lazy.compactMap { NSFont(name: $0, size: size) }.first ?? NSFont.systemFont(ofSize: size, weight: .black)
        let base = color.usingColorSpace(.sRGB) ?? color
        func shade(_ k: CGFloat, alpha: CGFloat = 1) -> NSColor {
            NSColor(red: min(1, base.redComponent * k), green: min(1, base.greenComponent * k), blue: min(1, base.blueComponent * k), alpha: alpha)
        }
        let dark = shade(0.35)
        let light = NSColor(red: min(1, base.redComponent + 0.35), green: min(1, base.greenComponent + 0.35), blue: min(1, base.blueComponent + 0.35), alpha: 0.55)

        // lay the glyphs out by hand so each can lean and bob on its own
        struct Glyph { var s: String; var x: CGFloat; var w: CGFloat; var dy: CGFloat; var rot: CGFloat }
        var glyphs: [Glyph] = []
        var x: CGFloat = 0
        for ch in text {
            let s = String(ch)
            let w = NSAttributedString(string: s, attributes: [.font: font]).size().width
            glyphs.append(Glyph(s: s, x: x, w: w, dy: CGFloat(rng.unit() * 10 - 5), rot: CGFloat(rng.unit() * 0.16 - 0.08)))
            x += w * 0.94
        }
        let textW = x + (glyphs.last.map { $0.w * 0.06 } ?? 0)
        let margin: CGFloat = 70, dripRoom: CGFloat = 110
        let W = textW + margin * 2, H = size * 1.25 + dripRoom + margin
        let baseline = dripRoom + margin * 0.4
        let pw = Int(W * 1.5), ph = Int(H * 1.5)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: 1.5, y: 1.5)
        ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
        let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx

        // the whole tag leans back a touch
        ctx.translateBy(x: W / 2, y: H / 2)
        ctx.rotate(by: -0.045)
        ctx.translateBy(x: -W / 2, y: -H / 2)

        func eachGlyph(_ attrs: [NSAttributedString.Key: Any], dx: CGFloat = 0, dy: CGFloat = 0) {
            for g in glyphs {
                ctx.saveGState()
                ctx.translateBy(x: margin + g.x + g.w / 2 + dx, y: baseline + g.dy + dy)
                ctx.rotate(by: g.rot)
                NSAttributedString(string: g.s, attributes: attrs).draw(at: CGPoint(x: -g.w / 2, y: 0))
                ctx.restoreGState()
            }
        }

        // overspray: the letters drawn through a wide soft shadow, twice
        ctx.saveGState()
        ctx.setShadow(offset: CGSize.zero, blur: 34, color: shade(0.9, alpha: 0.6).cgColor)
        eachGlyph([.font: font, .foregroundColor: shade(0.9, alpha: 0.5)])
        eachGlyph([.font: font, .foregroundColor: shade(0.9, alpha: 0.5)])
        ctx.restoreGState()

        // speckle around the letters
        for _ in 0..<140 {
            let px = margin * 0.3 + CGFloat(rng.unit()) * (W - margin * 0.6)
            let py = baseline - 30 + CGFloat(rng.unit()) * (size * 1.2 + 40)
            let r = 0.8 + CGFloat(rng.unit()) * 2.6
            ctx.setFillColor(shade(0.85, alpha: 0.08 + CGFloat(rng.unit()) * 0.3).cgColor)
            ctx.fillEllipse(in: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2))
        }

        // drips off the bottoms of a few letters, under the paint
        let dripCount = min(glyphs.count, max(2, glyphs.count / 3))
        var dripAt = Set<Int>()
        while dripAt.count < dripCount { dripAt.insert(Int(rng.unit() * Double(glyphs.count)) % glyphs.count) }
        for i in dripAt.sorted() {
            let g = glyphs[i]
            let dx = margin + g.x + g.w * (0.3 + CGFloat(rng.unit()) * 0.4)
            let w = 5 + CGFloat(rng.unit()) * 5
            let len = 28 + CGFloat(rng.unit()) * 70
            let top = baseline + g.dy + 6
            ctx.setFillColor(shade(0.8).cgColor)
            ctx.fill(CGRect(x: dx - w / 2, y: top - len, width: w, height: len))
            ctx.fillEllipse(in: CGRect(x: dx - w / 2 - 1.5, y: top - len - w / 2 - 1.5, width: w + 3, height: w + 3))
        }

        // dark outline, then the face, then a thin highlight up and left
        eachGlyph([.font: font, .foregroundColor: dark, .strokeColor: dark, .strokeWidth: -9])
        eachGlyph([.font: font, .foregroundColor: base])
        eachGlyph([.font: font, .foregroundColor: light, .strokeColor: light, .strokeWidth: 2.2], dx: -2.5, dy: 2.5)

        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { return nil }
        return (img, Float(W / H))
    }

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }
}
