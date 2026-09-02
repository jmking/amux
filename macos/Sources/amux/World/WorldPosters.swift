import RealityKit
import AppKit
import simd

// MARK: - Posters
//
// Paper on the wall, drawn with CoreGraphics into textures: a mask poster,
// a headless-suit poster and a small sticker, in the hacktivist idiom. The
// drawings are our own: the mask is a plain shield with slot eyes (not the
// film mask), and the suit-with-a-question-mark deliberately quotes the
// Anonymous motif without its globe and laurels. Lit like paper, not glowing,
// hung slightly crooked with tape at the corners drawn into the sheet.

enum WorldPoster {
    case legion, expectUs, onlyRoot

    /// A sheet `width` metres wide, centred at the origin, facing +z.
    @MainActor
    static func make(_ kind: WorldPoster, width: Float) async -> ModelEntity? {
        guard let (image, aspect) = draw(kind),
              let tex = try? await TextureResource(image: image, options: .init(semantic: .color)) else { return nil }
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: .white, texture: .init(tex))
        m.roughness = .init(floatLiteral: 0.85)
        m.metallic = .init(floatLiteral: 0)
        m.blending = .transparent(opacity: 1.0)
        m.opacityThreshold = 0.5
        let e = ModelEntity(mesh: .generatePlane(width: width, height: width / aspect), materials: [m])
        return e
    }

    private static func font(_ names: [String], _ size: CGFloat, weight: NSFont.Weight = .black) -> NSFont {
        names.lazy.compactMap { NSFont(name: $0, size: size) }.first ?? NSFont.systemFont(ofSize: size, weight: weight)
    }
    private static let display = ["Impact", "HelveticaNeue-CondensedBlack", "AvenirNextCondensed-Heavy"]
    private static let mono = ["Menlo-Bold", "Courier-Bold"]

    private static func draw(_ kind: WorldPoster) -> (CGImage, Float)? {
        let W: CGFloat, H: CGFloat
        switch kind {
        case .legion, .expectUs: (W, H) = (600, 850)
        case .onlyRoot: (W, H) = (400, 400)
        }
        guard let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
        let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        defer { NSGraphicsContext.restoreGraphicsState() }

        func text(_ s: String, _ f: NSFont, _ color: NSColor, at y: CGFloat, centredIn w: CGFloat = W, kern: CGFloat = 0) {
            let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color, .kern: kern])
            let sz = a.size()
            a.draw(at: CGPoint(x: (w - sz.width + kern) / 2, y: y))
        }
        func tape(_ rect: CGRect, angle: CGFloat) {
            ctx.saveGState()
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: angle)
            ctx.setFillColor(CGColor(red: 0.95, green: 0.93, blue: 0.85, alpha: 0.78))
            ctx.fill(CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
            ctx.restoreGState()
        }
        // a sheet of paper, a touch off-white, with a worn edge
        func paper(_ color: CGColor) {
            let inset: CGFloat = 4
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: inset, y: inset, width: W - inset * 2, height: H - inset * 2))
        }

        switch kind {
        case .legion:
            paper(CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1))
            // a mask of our own: a smooth shield shape, narrow eyes, a thin
            // straight mouth, cheek marks. No moustache, no goatee.
            let cx = W / 2, cy = H * 0.62
            let mask = CGMutablePath()
            mask.move(to: CGPoint(x: cx, y: cy - 200))
            mask.addCurve(to: CGPoint(x: cx - 150, y: cy + 60), control1: CGPoint(x: cx - 90, y: cy - 190), control2: CGPoint(x: cx - 160, y: cy - 60))
            mask.addCurve(to: CGPoint(x: cx, y: cy + 190), control1: CGPoint(x: cx - 140, y: cy + 170), control2: CGPoint(x: cx - 70, y: cy + 190))
            mask.addCurve(to: CGPoint(x: cx + 150, y: cy + 60), control1: CGPoint(x: cx + 70, y: cy + 190), control2: CGPoint(x: cx + 140, y: cy + 170))
            mask.addCurve(to: CGPoint(x: cx, y: cy - 200), control1: CGPoint(x: cx + 160, y: cy - 60), control2: CGPoint(x: cx + 90, y: cy - 190))
            ctx.setFillColor(CGColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 1))
            ctx.addPath(mask); ctx.fillPath()
            ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1))
            for sx: CGFloat in [-1, 1] {
                // eyes: slanted slots
                ctx.saveGState()
                ctx.translateBy(x: cx + sx * 62, y: cy + 50)
                ctx.rotate(by: sx * 0.22)
                ctx.fillEllipse(in: CGRect(x: -38, y: -12, width: 76, height: 24))
                ctx.restoreGState()
                // cheek marks
                ctx.fill(CGRect(x: cx + sx * 95 - 4, y: cy - 60, width: 8, height: 46))
            }
            // the mouth: thin and level
            ctx.fill(CGRect(x: cx - 48, y: cy - 118, width: 96, height: 9))
            text("WE ARE", font(display, 92), NSColor(white: 0.95, alpha: 1), at: H * 0.215, kern: 6)
            text("LEGION", font(display, 128), NSColor(red: 0.95, green: 0.2, blue: 0.22, alpha: 1), at: H * 0.03, kern: 8)
            text("we do not forget", font(mono, 22), NSColor(white: 0.6, alpha: 1), at: H * 0.90)
            tape(CGRect(x: 30, y: H - 50, width: 90, height: 28), angle: -0.5)
            tape(CGRect(x: W - 120, y: H - 50, width: 90, height: 28), angle: 0.6)

        case .expectUs:
            paper(CGColor(red: 0.90, green: 0.88, blue: 0.82, alpha: 1))
            // a suit with nobody in it: shoulders, lapels, a tie, and a
            // question mark where the head would be
            let cx = W / 2, base = H * 0.30
            let ink = CGColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)
            ctx.setFillColor(ink)
            let shoulders = CGMutablePath()
            shoulders.move(to: CGPoint(x: cx - 190, y: base))
            shoulders.addLine(to: CGPoint(x: cx - 175, y: base + 175))
            shoulders.addQuadCurve(to: CGPoint(x: cx - 60, y: base + 230), control: CGPoint(x: cx - 150, y: base + 225))
            shoulders.addLine(to: CGPoint(x: cx + 60, y: base + 230))
            shoulders.addQuadCurve(to: CGPoint(x: cx + 175, y: base + 175), control: CGPoint(x: cx + 150, y: base + 225))
            shoulders.addLine(to: CGPoint(x: cx + 190, y: base))
            shoulders.closeSubpath()
            ctx.addPath(shoulders); ctx.fillPath()
            // shirt and lapels
            ctx.setFillColor(CGColor(red: 0.90, green: 0.88, blue: 0.82, alpha: 1))
            let shirt = CGMutablePath()
            shirt.move(to: CGPoint(x: cx - 72, y: base + 230))
            shirt.addLine(to: CGPoint(x: cx, y: base + 30))
            shirt.addLine(to: CGPoint(x: cx + 72, y: base + 230))
            shirt.closeSubpath()
            ctx.addPath(shirt); ctx.fillPath()
            ctx.setFillColor(ink)
            let tie = CGMutablePath()
            tie.move(to: CGPoint(x: cx - 12, y: base + 215))
            tie.addLine(to: CGPoint(x: cx + 12, y: base + 215))
            tie.addLine(to: CGPoint(x: cx + 17, y: base + 110))
            tie.addLine(to: CGPoint(x: cx, y: base + 84))
            tie.addLine(to: CGPoint(x: cx - 17, y: base + 110))
            tie.closeSubpath()
            ctx.addPath(tie); ctx.fillPath()
            text("?", font(display, 210), NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1), at: base + 240)
            text("EXPECT US", font(display, 96), NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1), at: H * 0.09, kern: 4)
            text("we are legion", font(mono, 22), NSColor(white: 0.35, alpha: 1), at: H * 0.04)
            // a red stamp, askew
            ctx.saveGState()
            ctx.translateBy(x: W * 0.78, y: H * 0.88)
            ctx.rotate(by: -0.3)
            ctx.setStrokeColor(CGColor(red: 0.8, green: 0.12, blue: 0.14, alpha: 0.85))
            ctx.setLineWidth(5)
            ctx.stroke(CGRect(x: -80, y: -24, width: 160, height: 48))
            let stamp = NSAttributedString(string: "NOT FORGIVEN", attributes: [.font: font(display, 24), .foregroundColor: NSColor(red: 0.8, green: 0.12, blue: 0.14, alpha: 0.85)])
            stamp.draw(at: CGPoint(x: -stamp.size().width / 2, y: -stamp.size().height / 2))
            ctx.restoreGState()
            tape(CGRect(x: W / 2 - 45, y: H - 46, width: 90, height: 28), angle: 0.15)
            tape(CGRect(x: 26, y: 22, width: 80, height: 26), angle: 0.7)

        case .onlyRoot:
            paper(CGColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1))
            ctx.setStrokeColor(CGColor(red: 0.3, green: 0.9, blue: 0.5, alpha: 1))
            ctx.setLineWidth(6)
            ctx.stroke(CGRect(x: 22, y: 22, width: W - 44, height: H - 44))
            let green = NSColor(red: 0.3, green: 0.9, blue: 0.5, alpha: 1)
            text("NO GODS", font(mono, 46), green, at: H * 0.71)
            text("NO KINGS", font(mono, 46), green, at: H * 0.55)
            text("ONLY ROOT", font(mono, 46), NSColor(white: 0.95, alpha: 1), at: H * 0.35)
            text("$ sudo -i", font(mono, 22), NSColor(white: 0.5, alpha: 1), at: H * 0.17)
        }
        guard let img = ctx.makeImage() else { return nil }
        return (img, Float(W / H))
    }
}
