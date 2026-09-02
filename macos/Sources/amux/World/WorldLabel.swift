import RealityKit
import AppKit
import CoreGraphics

// MARK: - Labels
//
// Name tags and markers are drawn with CoreGraphics into a texture on a single
// quad. The first version extruded them as text meshes, which cost several
// hundred thousand triangles per tag; a textured quad is two triangles and
// looks better besides, because it can have a soft pill background, a status
// dot and a brand glyph in colour the way the reference does.

@MainActor
enum WorldLabel {
    /// Points per metre of quad: the texture is drawn at this density, then the
    /// quad is sized so text reads at the camera's framing.
    private static let pointsPerMetre: CGFloat = 96
    private static let renderScale: CGFloat = 2

    struct Spec: Equatable {
        var text: String
        var glyph: String? = nil
        var glyphColor: NSColor = .white
        /// A product mark drawn where the glyph would go, in place of it.
        var icon: NSImage? = nil
        var dot: NSColor? = nil
        var textColor: NSColor = .white
        var background: NSColor? = NSColor(white: 0.06, alpha: 0.86)
        var fontSize: CGFloat = 15
        var weight: NSFont.Weight = .semibold
    }

    /// A quad in the XY plane facing +Z, its bottom-centre at the origin.
    static func make(_ spec: Spec) async -> ModelEntity? {
        guard let (image, size) = draw(spec) else { return nil }
        guard let tex = try? await TextureResource(image: image, options: .init(semantic: .color)) else { return nil }
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(tex))
        m.blending = .transparent(opacity: 1.0)
        m.opacityThreshold = 0
        let w = Float(size.width / pointsPerMetre), h = Float(size.height / pointsPerMetre)
        let e = ModelEntity(mesh: .generatePlane(width: w, height: h), materials: [m])
        e.position.y = h / 2
        return e
    }

    /// Redraws an existing label's texture in place, keeping the entity.
    static func update(_ entity: ModelEntity, _ spec: Spec) async {
        guard let (image, size) = draw(spec),
              let tex = try? await TextureResource(image: image, options: .init(semantic: .color)) else { return }
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(tex))
        m.blending = .transparent(opacity: 1.0)
        m.opacityThreshold = 0
        let w = Float(size.width / pointsPerMetre), h = Float(size.height / pointsPerMetre)
        entity.model = ModelComponent(mesh: .generatePlane(width: w, height: h), materials: [m])
        entity.position.y = h / 2
    }

    private static func draw(_ spec: Spec) -> (CGImage, CGSize)? {
        let font = NSFont.systemFont(ofSize: spec.fontSize, weight: spec.weight)
        let glyphFont = NSFont.systemFont(ofSize: spec.fontSize * 0.95, weight: .bold)
        let text = NSAttributedString(string: spec.text, attributes: [.font: font, .foregroundColor: spec.textColor])
        let glyph = spec.glyph.map { NSAttributedString(string: $0, attributes: [.font: glyphFont, .foregroundColor: spec.glyphColor]) }
        let padX: CGFloat = spec.background == nil ? 2 : 11
        let padY: CGFloat = spec.background == nil ? 2 : 6
        let gap: CGFloat = 6
        let dotD: CGFloat = spec.dot == nil ? 0 : 7
        let textSize = text.size()
        let iconSide: CGFloat = spec.icon == nil ? 0 : ceil(textSize.height * 0.95)
        let glyphSize = spec.icon != nil ? CGSize(width: iconSide, height: iconSide) : (glyph?.size() ?? .zero)
        var w = padX * 2 + textSize.width
        if dotD > 0 { w += dotD + gap }
        if glyphSize.width > 0 { w += glyphSize.width + gap * 0.7 }
        let h = padY * 2 + max(textSize.height, glyphSize.height)
        let size = CGSize(width: ceil(w), height: ceil(h))

        let pw = Int(size.width * renderScale), ph = Int(size.height * renderScale)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: renderScale, y: renderScale)
        let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx

        if let bg = spec.background {
            let path = NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: size.height / 2, yRadius: size.height / 2)
            bg.setFill()
            path.fill()
        }
        var x = padX
        if let dot = spec.dot {
            dot.setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: (size.height - dotD) / 2, width: dotD, height: dotD)).fill()
            x += dotD + gap
        }
        if let icon = spec.icon {
            let r = CGRect(x: x, y: (size.height - iconSide) / 2, width: iconSide, height: iconSide)
            NSGraphicsContext.current?.imageInterpolation = .high
            icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            x += iconSide + gap * 0.7
        } else if let glyph {
            glyph.draw(at: CGPoint(x: x, y: (size.height - glyphSize.height) / 2))
            x += glyphSize.width + gap * 0.7
        }
        text.draw(at: CGPoint(x: x, y: (size.height - textSize.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { return nil }
        return (img, size)
    }
}
