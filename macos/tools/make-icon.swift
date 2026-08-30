import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

// macOS icons sit inside the grid with breathing room
let margin = 92.0
let rect = NSRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
// squircle-ish radius, ~22.5% of the tile like Apple's grid
let tile = NSBezierPath(roundedRect: rect, xRadius: 188, yRadius: 188)

// same teal as the sidebar chip (pal.spot)
NSColor(srgbRed: 0x73/255.0, green: 0xda/255.0, blue: 0xca/255.0, alpha: 1).setFill()
tile.fill()

// dark glyph, same as spotInk
let ink = NSColor(srgbRed: 0x13/255.0, green: 0x13/255.0, blue: 0x13/255.0, alpha: 1)
let font = NSFont(name: "Menlo-Bold", size: 450)
    ?? NSFont.monospacedSystemFont(ofSize: 450, weight: .bold)
let text = NSAttributedString(string: "❯a", attributes: [
    .font: font,
    .foregroundColor: ink,
    .kern: -38,
])
let ts = text.size()
// optical centering: monospace leaves the glyph high in its line box
text.draw(at: NSPoint(x: (size - ts.width) / 2,
                      y: (size - ts.height) / 2 + 6))

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "/tmp/amux-icon-1024.png"))
print("written")
