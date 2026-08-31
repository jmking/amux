import Metal
import MetalKit
import simd
import AppKit

// MARK: - The agent world, rendered directly in Metal
//
// Everything an avatar does is a function of (phase, time, seed), so the motion
// lives in the vertex shader and the CPU never animates anything. Per-instance
// data is rewritten only when the agent list changes; a steady frame costs one
// small uniform write and five draw calls, whatever the agent count.
//
// The shader is compiled from source at runtime rather than shipped as a
// .metal file. SwiftPM would put the resulting metallib in a resource bundle,
// and this app is assembled by hand, so that bundle has no Info.plist and
// Bundle.module traps. That already caused one crash-on-launch; not again.

// MARK: Layout shared with the shader
//
// Every field is float4-aligned so Swift and MSL agree without padding games.

/// Mirrors `struct Vertex { float4 position; float4 normal; }` in the shader.
/// Declared as SIMD4 rather than SIMD3 plus padding on purpose: a SIMD3<Float>
/// already occupies 16 bytes in Swift, so hand-written pad fields push the
/// stride to 64 while the shader still reads 32, and every vertex past the
/// first comes back as garbage.
struct WorldVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>

    init(position: SIMD3<Float>, normal: SIMD3<Float>) {
        self.position = SIMD4(position, 1)
        self.normal = SIMD4(normal, 0)
    }
}

struct WorldUniforms {
    var viewProj: matrix_float4x4
    var camera: SIMD4<Float>      // xyz eye, w time
    var light: SIMD4<Float>       // xyz direction, w floor fade
}

/// phase: 0 thinking, 1 tool, 2 network, 3 waiting, 4 done, 5 idle
/// kind:  0 body, 1 head, 2 orb, 3 marker
struct WorldInstance {
    var posScale: SIMD4<Float>    // xyz position, w uniform scale
    var color: SIMD4<Float>
    var anim: SIMD4<Float>        // x phase, y seed, z phaseStart, w kind
}

enum WorldPhaseCode {
    static func code(_ p: AgentPhase) -> Float {
        switch p {
        case .thinking: return 0
        case .tool: return 1
        case .network: return 2
        case .waiting: return 3
        case .done: return 4
        case .idle: return 5
        }
    }
}

// MARK: - Shader

private let worldShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProj;
    float4   camera;   // xyz eye, w time
    float4   light;    // xyz dir
};

struct Instance {
    float4 posScale;
    float4 color;
    float4 anim;       // x phase, y seed, z phaseStart, w kind
};

struct Vertex {
    float4 position;
    float4 normal;
};

struct VOut {
    float4 position [[position]];
    float3 normal;
    float3 world;
    float4 color;
};

// All avatar motion. Driven purely by (phase, seed, elapsed) so the CPU never
// touches an instance once it is written.
static float3 phaseOffset(float phase, float seed, float t) {
    if (phase < 0.5) {                       // thinking: slow float
        return float3(0.0, 0.06 * sin(t * 1.15 + seed), 0.0);
    } else if (phase < 1.5) {                // tool: quick heads-down bob
        return float3(0.0, -0.05 * abs(sin(t * 6.2 + seed)), 0.0);
    } else if (phase < 2.5) {                // network: gentle lift
        return float3(0.0, 0.03 * sin(t * 2.1 + seed), 0.0);
    } else if (phase < 3.5) {                // waiting: insistent hop
        return float3(0.0, 0.17 * abs(sin(t * 4.6 + seed)), 0.0);
    } else if (phase < 4.5) {                // done: one decaying hop
        float h = exp(-3.0 * t) * abs(sin(t * 7.5));
        return float3(0.0, 0.55 * h, 0.0);
    }
    float s = sin(t * 0.75 + seed);          // idle: barely-there sway
    return float3(0.04 * s, 0.015 * sin(t * 0.9 + seed), 0.0);
}

vertex VOut world_vertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         device const Vertex*   verts [[buffer(0)]],
                         constant Uniforms&     u     [[buffer(1)]],
                         device const Instance* inst  [[buffer(2)]]) {
    Instance I = inst[iid];
    float phase = I.anim.x, seed = I.anim.y, kind = I.anim.w;
    float t = u.camera.w - I.anim.z;

    float3 offset = phaseOffset(phase, seed, t);
    float scale = I.posScale.w;

    if (kind > 1.5 && kind < 2.5) {          // orb: thought bubble / packet
        if (phase < 0.5) {
            scale *= 1.15 + 0.35 * sin(t * 3.4 + seed);
        } else if (phase > 1.5 && phase < 2.5) {
            float u01 = fract(t * 0.75 + seed);
            float tri = 1.0 - abs(u01 * 2.0 - 1.0);
            offset += float3(0.0, 1.4 * tri, -3.0 * tri);
        }
    }
    if (kind > 2.5) {                        // marker: waves side to side
        offset.x += 0.10 * sin(t * 9.0);
    }

    float3 world = I.posScale.xyz + offset + verts[vid].position.xyz * scale;
    VOut o;
    o.position = u.viewProj * float4(world, 1.0);
    o.normal = verts[vid].normal.xyz;
    o.world = world;
    o.color = I.color;
    return o;
}

fragment float4 world_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
    float3 n = normalize(in.normal);
    float3 l = normalize(u.light.xyz);
    float lambert = max(dot(n, l), 0.0);
    float3 view = normalize(u.camera.xyz - in.world);
    float rim = pow(1.0 - max(dot(n, view), 0.0), 2.5) * 0.35;
    float3 lit = in.color.rgb * (0.34 + 0.72 * lambert) + rim;
    return float4(lit, in.color.a);
}

// The floor is one quad; its grid is procedural so there is no texture to
// sample and no geometry to grow.
vertex VOut floor_vertex(uint vid [[vertex_id]],
                         device const Vertex* verts [[buffer(0)]],
                         constant Uniforms&   u     [[buffer(1)]]) {
    float3 world = verts[vid].position.xyz;
    VOut o;
    o.position = u.viewProj * float4(world, 1.0);
    o.normal = float3(0.0, 1.0, 0.0);
    o.world = world;
    o.color = float4(0.0);
    return o;
}

fragment float4 floor_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
    float2 g = abs(fract(in.world.xz * 0.5) - 0.5) / fwidth(in.world.xz * 0.5);
    float line = 1.0 - min(min(g.x, g.y), 1.0);
    float3 base = float3(0.137, 0.137, 0.149);
    float3 col = mix(base, float3(0.22, 0.22, 0.245), line * 0.65);
    float fade = 1.0 - smoothstep(6.0, 17.0, length(in.world.xz));
    return float4(col * fade, fade);
}

// Nameplates: camera-facing quads sampling a text texture rendered once.
struct LOut {
    float4 position [[position]];
    float2 uv;
    float  alpha;
};

vertex LOut label_vertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         constant Uniforms&     u    [[buffer(1)]],
                         device const Instance* inst [[buffer(2)]],
                         device const float2*   quad [[buffer(3)]]) {
    Instance I = inst[iid];
    float t = u.camera.w - I.anim.z;
    float3 offset = phaseOffset(I.anim.x, I.anim.y, t);
    float3 centre = I.posScale.xyz + offset;

    float3 fwd = normalize(u.camera.xyz - centre);
    float3 right = normalize(cross(float3(0.0, 1.0, 0.0), fwd));
    float3 up = cross(fwd, right);

    float2 c = quad[vid];
    float3 world = centre + right * c.x * I.posScale.w * I.color.x
                          + up    * c.y * I.posScale.w;
    LOut o;
    o.position = u.viewProj * float4(world, 1.0);
    o.uv = float2(c.x + 0.5, 0.5 - c.y);
    o.alpha = I.color.w;
    return o;
}

fragment float4 label_fragment(LOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               sampler samp [[sampler(0)]]) {
    float4 t = tex.sample(samp, in.uv);
    return float4(t.rgb, t.a * in.alpha);
}
"""

// MARK: - Meshes

struct WorldMesh {
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let indexCount: Int
}

enum MeshBuilder {
    /// Unit sphere, used for heads and orbs.
    static func sphere(_ device: MTLDevice, rings: Int = 12, segments: Int = 18) -> WorldMesh {
        var verts: [WorldVertex] = []
        var idx: [UInt16] = []
        for r in 0...rings {
            let phi = Float.pi * Float(r) / Float(rings)
            for s in 0...segments {
                let theta = 2 * Float.pi * Float(s) / Float(segments)
                let n = SIMD3<Float>(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
                verts.append(WorldVertex(position: n, normal: n))
            }
        }
        let stride = segments + 1
        for r in 0..<rings {
            for s in 0..<segments {
                let a = UInt16(r * stride + s), b = UInt16((r + 1) * stride + s)
                idx += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        return upload(device, verts, idx)
    }

    /// Capsule of unit radius and the given body height, used for torsos.
    static func capsule(_ device: MTLDevice, height: Float = 1.0,
                        rings: Int = 8, segments: Int = 16) -> WorldMesh {
        var verts: [WorldVertex] = []
        var idx: [UInt16] = []
        let half = height / 2
        // two hemispheres joined by a cylinder, walked as one ring stack
        let total = rings * 2 + 1
        for r in 0...total {
            let f = Float(r) / Float(total)
            let phi = Float.pi * f
            let n = SIMD3<Float>(sin(phi), cos(phi), 0)
            let yOffset: Float = f < 0.5 ? half : -half
            for s in 0...segments {
                let theta = 2 * Float.pi * Float(s) / Float(segments)
                let nn = SIMD3<Float>(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
                let p = SIMD3<Float>(nn.x, nn.y + yOffset, nn.z)
                verts.append(WorldVertex(position: p, normal: normalize(SIMD3(nn.x, n.y, nn.z))))
            }
        }
        let stride = segments + 1
        for r in 0..<total {
            for s in 0..<segments {
                let a = UInt16(r * stride + s), b = UInt16((r + 1) * stride + s)
                idx += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        return upload(device, verts, idx)
    }

    /// Half-extents are baked in because an instance carries only a uniform
    /// scale, and the attention flag is a thin post rather than a cube.
    static func box(_ device: MTLDevice, half: SIMD3<Float> = SIMD3(0.045, 0.21, 0.045))
        -> WorldMesh {
        var verts: [WorldVertex] = []
        var idx: [UInt16] = []
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
            (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0)),
            (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)),
            (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)),
            (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
        ]
        for (n, u, v) in faces {
            let base = UInt16(verts.count)
            for (su, sv) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
                verts.append(WorldVertex(position: (n + u * su + v * sv) * half, normal: n))
            }
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return upload(device, verts, idx)
    }

    /// Ground plane, big enough that its own fade reaches zero before the edge.
    static func floor(_ device: MTLDevice, extent: Float = 20) -> WorldMesh {
        let n = SIMD3<Float>(0, 1, 0)
        let verts = [
            WorldVertex(position: SIMD3(-extent, 0, -extent), normal: n),
            WorldVertex(position: SIMD3(extent, 0, -extent), normal: n),
            WorldVertex(position: SIMD3(extent, 0, extent), normal: n),
            WorldVertex(position: SIMD3(-extent, 0, extent), normal: n),
        ]
        return upload(device, verts, [0, 1, 2, 0, 2, 3])
    }

    private static func upload(_ device: MTLDevice, _ v: [WorldVertex], _ i: [UInt16]) -> WorldMesh {
        let vb = device.makeBuffer(bytes: v, length: MemoryLayout<WorldVertex>.stride * v.count,
                                   options: .storageModeShared)!
        let ib = device.makeBuffer(bytes: i, length: MemoryLayout<UInt16>.stride * i.count,
                                   options: .storageModeShared)!
        return WorldMesh(vertices: vb, indices: ib, indexCount: i.count)
    }
}

// MARK: - Matrices

enum M {
    static func perspective(hFovRadians: Float, aspect: Float, near: Float, far: Float)
        -> matrix_float4x4 {
        // Pinned horizontally: a world pane split narrow must not crop the room.
        let x = 1 / tan(hFovRadians / 2)
        let y = x * aspect
        let z = far / (far - near)
        return matrix_float4x4(columns: (
            SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, 1), SIMD4(0, 0, -z * near, 0)))
    }

    static func lookAt(eye: SIMD3<Float>, centre: SIMD3<Float>, up: SIMD3<Float>)
        -> matrix_float4x4 {
        // Left-handed to match the projection above, which clips z to [0,1] as
        // Metal expects. Taking cross(up, f) here instead builds a right-handed
        // basis, which mirrors the scene and turns the ground plane inside out.
        let f = normalize(centre - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        return matrix_float4x4(columns: (
            SIMD4(s.x, u.x, f.x, 0), SIMD4(s.y, u.y, f.y, 0), SIMD4(s.z, u.z, f.z, 0),
            SIMD4(-dot(s, eye), -dot(u, eye), -dot(f, eye), 1)))
    }
}

// MARK: - Label textures

/// One small texture per distinct name, drawn once with CoreGraphics and kept
/// until the label changes. Text is the only thing here that is not procedural.
final class LabelCache {
    private var textures: [String: (MTLTexture, Float)] = [:]
    private let device: MTLDevice

    init(device: MTLDevice) { self.device = device }

    /// Returns the texture and its aspect ratio (width / height).
    func texture(for text: String) -> (MTLTexture, Float)? {
        if let hit = textures[text] { return hit }
        let font = NSFont.systemFont(ofSize: 44, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let bounds = str.size()
        let w = max(Int(bounds.width.rounded(.up)) + 16, 8)
        let h = max(Int(bounds.height.rounded(.up)) + 8, 8)

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        str.draw(at: CGPoint(x: 8, y: 4))
        NSGraphicsContext.restoreGraphicsState()

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc), let data = ctx.data
        else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: w * 4)
        let entry = (tex, Float(w) / Float(h))
        textures[text] = entry
        return entry
    }

    func keep(only labels: Set<String>) {
        for k in textures.keys where !labels.contains(k) { textures.removeValue(forKey: k) }
    }
}

// MARK: - Renderer

/// What the renderer needs to know about one agent. Rebuilt only when the
/// roster or a phase changes, never per frame.
struct WorldAgentState: Equatable {
    let paneId: String
    let label: String
    let color: SIMD4<Float>
    let phase: AgentPhase
    let slot: Int
    let total: Int
}

final class WorldRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var solidPipeline: MTLRenderPipelineState!
    private var floorPipeline: MTLRenderPipelineState!
    private var labelPipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var labelDepthState: MTLDepthStencilState!
    private var sampler: MTLSamplerState!

    private var capsuleMesh: WorldMesh!
    private var sphereMesh: WorldMesh!
    private var boxMesh: WorldMesh!
    private var floorMesh: WorldMesh!
    private var quadBuffer: MTLBuffer!

    // instance data, rewritten only when agents change
    private var bodyInstances: [WorldInstance] = []
    private var sphereInstances: [WorldInstance] = []
    private var markerInstances: [WorldInstance] = []
    private var labelDraws: [(WorldInstance, MTLTexture)] = []
    private var bodyBuf, sphereBuf, markerBuf, labelBuf: MTLBuffer?

    private let labels: LabelCache
    private var start = CFAbsoluteTimeGetCurrent()
    private var phaseStarts: [String: Float] = [:]
    private var lastAgents: [WorldAgentState] = []

    // triple buffering keeps the CPU off the GPU's current uniform block
    private static let inFlight = 3
    private var uniformBuffers: [MTLBuffer] = []
    private var frameIndex = 0
    private let semaphore = DispatchSemaphore(value: inFlight)

    /// Two different questions, so two numbers.
    ///
    /// `lastFrameMs` is wall clock between presents, which is what the eye sees
    /// but also absorbs every main-thread stall: menu tracking, live resize,
    /// SwiftUI layout. A spike there is usually not the renderer.
    ///
    /// `worstGpuMs` is the GPU's own time for the pass, reported by the command
    /// buffer. That is the honest measure of whether this renderer can hold a
    /// frame budget, because it is the part the renderer controls.
    private(set) var lastFrameMs: Double = 0
    private(set) var worstFrameMs: Double = 0
    private(set) var lastGpuMs: Double = 0
    private(set) var worstGpuMs: Double = 0
    private var gpuTimes: [Double] = []
    private var frameTimes: [Double] = []
    private var framesSeen = 0
    private var lastPresent = CFAbsoluteTimeGetCurrent()

    var aspect: Float = 1.6

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.labels = LabelCache(device: device)
        super.init()
        guard buildPipelines() else { return nil }
        capsuleMesh = MeshBuilder.capsule(device)
        sphereMesh = MeshBuilder.sphere(device)
        boxMesh = MeshBuilder.box(device)
        floorMesh = MeshBuilder.floor(device)
        let quad: [SIMD2<Float>] = [
            SIMD2(-0.5, -0.5), SIMD2(0.5, -0.5), SIMD2(0.5, 0.5),
            SIMD2(-0.5, -0.5), SIMD2(0.5, 0.5), SIMD2(-0.5, 0.5),
        ]
        quadBuffer = device.makeBuffer(bytes: quad,
                                       length: MemoryLayout<SIMD2<Float>>.stride * quad.count,
                                       options: .storageModeShared)
        for _ in 0..<Self.inFlight {
            uniformBuffers.append(device.makeBuffer(
                length: MemoryLayout<WorldUniforms>.stride, options: .storageModeShared)!)
        }
    }

    private func buildPipelines() -> Bool {
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: worldShaderSource, options: nil)
        } catch {
            NSLog("amux: world shader failed to compile: \\(error)")
            return false
        }
        func pipeline(_ v: String, _ f: String, blend: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: v)
            d.fragmentFunction = library.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.depthAttachmentPixelFormat = .depth32Float
            if blend {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .sourceAlpha
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .sourceAlpha
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let solid = pipeline("world_vertex", "world_fragment", blend: false),
              let floor = pipeline("floor_vertex", "floor_fragment", blend: true),
              let label = pipeline("label_vertex", "label_fragment", blend: true)
        else { return false }
        solidPipeline = solid; floorPipeline = floor; labelPipeline = label

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dd)
        // labels read depth but do not write it, so they never z-fight each other
        let ld = MTLDepthStencilDescriptor()
        ld.depthCompareFunction = .less
        ld.isDepthWriteEnabled = false
        labelDepthState = device.makeDepthStencilState(descriptor: ld)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)
        return true
    }

    // MARK: agent roster -> instances

    private static let deskSpacing: Float = 2.6
    private static let perRow = 4

    private func slotPosition(_ slot: Int, _ total: Int) -> SIMD3<Float> {
        let rows = max(1, Int(ceil(Double(total) / Double(Self.perRow))))
        let row = slot / Self.perRow
        let inRow = min(Self.perRow, total - row * Self.perRow)
        let col = slot % Self.perRow
        return SIMD3(
            (Float(col) - Float(inRow - 1) / 2) * Self.deskSpacing,
            0,
            (Float(row) - Float(rows - 1) / 2) * Self.deskSpacing)
    }

    /// Rebuilds instance buffers. Called only when the roster or a phase changes,
    /// so per-frame cost stays flat.
    func update(agents: [WorldAgentState]) {
        guard agents != lastAgents else { return }
        let now = Float(CFAbsoluteTimeGetCurrent() - start)
        // a phase restart is what makes one-shots like `done` play
        for a in agents {
            let previous = lastAgents.first { $0.paneId == a.paneId }
            if previous?.phase != a.phase { phaseStarts[a.paneId] = now }
        }
        let liveIds = Set(agents.map(\.paneId))
        phaseStarts = phaseStarts.filter { liveIds.contains($0.key) }
        lastAgents = agents

        bodyInstances.removeAll(keepingCapacity: true)
        sphereInstances.removeAll(keepingCapacity: true)
        markerInstances.removeAll(keepingCapacity: true)
        labelDraws.removeAll(keepingCapacity: true)

        for a in agents {
            let base = slotPosition(a.slot, a.total)
            let phase = WorldPhaseCode.code(a.phase)
            let seed = Float(abs(a.paneId.hashValue % 1000)) / 160.0
            let started = phaseStarts[a.paneId] ?? now
            let anim = SIMD4<Float>(phase, seed, started, 0)

            bodyInstances.append(WorldInstance(
                posScale: SIMD4(base.x, base.y + 0.62, base.z, 0.3),
                color: a.color, anim: anim))
            sphereInstances.append(WorldInstance(
                posScale: SIMD4(base.x, base.y + 1.22, base.z, 0.24),
                color: mix(a.color, SIMD4(1, 1, 1, 1), t: 0.4),
                anim: SIMD4(phase, seed, started, 1)))

            // orb only exists for thinking and network; elsewhere it collapses
            let orbScale: Float = (a.phase == .thinking || a.phase == .network) ? 0.1 : 0
            let orbColor: SIMD4<Float> = a.phase == .network
                ? SIMD4(0.42, 0.85, 0.83, 1) : SIMD4(0.95, 0.95, 1, 1)
            sphereInstances.append(WorldInstance(
                posScale: SIMD4(base.x, base.y + 1.78, base.z, orbScale),
                color: orbColor, anim: SIMD4(phase, seed, started, 2)))

            let markScale: Float = a.phase == .waiting ? 1 : 0
            markerInstances.append(WorldInstance(
                posScale: SIMD4(base.x, base.y + 1.95, base.z, markScale),
                color: SIMD4(0.85, 0.3, 0.28, 1),
                anim: SIMD4(phase, seed, started, 3)))

            if let (tex, ratio) = labels.texture(for: a.label) {
                // color.x carries the aspect ratio, color.w the opacity
                labelDraws.append((WorldInstance(
                    posScale: SIMD4(base.x, base.y + 2.12, base.z, 0.32),
                    color: SIMD4(ratio, 0, 0, 0.92),
                    anim: SIMD4(phase, seed, started, 4)), tex))
            }
        }
        labels.keep(only: Set(agents.map(\.label)))
        bodyBuf = buffer(bodyInstances)
        sphereBuf = buffer(sphereInstances)
        markerBuf = buffer(markerInstances)
        labelBuf = buffer(labelDraws.map(\.0))
    }

    private func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, t: Float) -> SIMD4<Float> {
        a + (b - a) * t
    }

    private func buffer(_ instances: [WorldInstance]) -> MTLBuffer? {
        guard !instances.isEmpty else { return nil }
        return device.makeBuffer(bytes: instances,
                                 length: MemoryLayout<WorldInstance>.stride * instances.count,
                                 options: .storageModeShared)
    }

    // MARK: draw

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspect = size.height > 0 ? Float(size.width / size.height) : 1.6
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commands = queue.makeCommandBuffer() else { return }

        semaphore.wait()
        let cpuStart = CFAbsoluteTimeGetCurrent()
        frameIndex = (frameIndex + 1) % Self.inFlight
        let uniformBuffer = uniformBuffers[frameIndex]

        let eye = SIMD3<Float>(0, 6.5, 12.5)
        let view4 = M.lookAt(eye: eye, centre: SIMD3(0, 1.0, 0), up: SIMD3(0, 1, 0))
        let proj = M.perspective(hFovRadians: 42 * .pi / 180, aspect: aspect,
                                 near: 0.1, far: 120)
        var uniforms = WorldUniforms(
            viewProj: proj * view4,
            camera: SIMD4(eye.x, eye.y, eye.z, Float(CFAbsoluteTimeGetCurrent() - start)),
            light: SIMD4(normalize(SIMD3<Float>(0.45, 0.85, 0.35)), 0))
        uniformBuffer.contents().copyMemory(from: &uniforms,
                                            byteCount: MemoryLayout<WorldUniforms>.stride)

        guard let enc = commands.makeRenderCommandEncoder(descriptor: descriptor) else {
            semaphore.signal(); return
        }
        enc.setDepthStencilState(depthState)
        // No culling. The projection is left-handed (Metal clips z to [0,1])
        // while lookAt builds a right-handed basis, so face winding is not
        // reliably consistent between the meshes and the floor. At this vertex
        // count culling buys nothing worth a class of invisible-geometry bugs.
        enc.setCullMode(.none)

        enc.setRenderPipelineState(floorPipeline)
        enc.setVertexBuffer(floorMesh.vertices, offset: 0, index: 0)
        enc.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        enc.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: floorMesh.indexCount,
                                  indexType: .uint16, indexBuffer: floorMesh.indices,
                                  indexBufferOffset: 0)

        enc.setRenderPipelineState(solidPipeline)
        func drawInstanced(_ mesh: WorldMesh, _ buf: MTLBuffer?, _ count: Int) {
            guard let buf, count > 0 else { return }
            enc.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
            enc.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            enc.setVertexBuffer(buf, offset: 0, index: 2)
            enc.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                      indexType: .uint16, indexBuffer: mesh.indices,
                                      indexBufferOffset: 0, instanceCount: count)
        }
        drawInstanced(capsuleMesh, bodyBuf, bodyInstances.count)
        drawInstanced(sphereMesh, sphereBuf, sphereInstances.count)
        drawInstanced(boxMesh, markerBuf, markerInstances.count)

        if let labelBuf, !labelDraws.isEmpty {
            enc.setRenderPipelineState(labelPipeline)
            enc.setDepthStencilState(labelDepthState)
            enc.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            enc.setVertexBuffer(labelBuf, offset: 0, index: 2)
            enc.setVertexBuffer(quadBuffer, offset: 0, index: 3)
            enc.setFragmentSamplerState(sampler, index: 0)
            // one draw per label: each has its own texture, and there are only
            // ever as many labels as there are live agents
            for (i, entry) in labelDraws.enumerated() {
                enc.setFragmentTexture(entry.1, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                   instanceCount: 1, baseInstance: i)
            }
        }
        enc.endEncoding()

        commands.addCompletedHandler { [weak self] buf in
            guard let self else { return }
            let gpu = (buf.gpuEndTime - buf.gpuStartTime) * 1000
            if gpu > 0 {
                self.lastGpuMs = gpu
                self.gpuTimes.append(gpu)
                if self.gpuTimes.count > 240 {
                    self.gpuTimes.removeFirst(self.gpuTimes.count - 240)
                }
                if self.gpuTimes.count > 20 { self.worstGpuMs = self.gpuTimes.max() ?? 0 }
            }
            self.semaphore.signal()
        }
        commands.present(drawable)
        commands.commit()

        let now = CFAbsoluteTimeGetCurrent()
        lastFrameMs = (now - lastPresent) * 1000
        lastPresent = now
        _ = cpuStart
        // The first frames include pipeline warm-up and the first drawable, which
        // are not representative, so they are dropped rather than averaged away.
        // Frames drawn while amux is not the active app are dropped too: macOS
        // throttles a background window, and counting that as a dropped frame
        // makes the figure say something it does not mean.
        framesSeen += 1
        guard framesSeen > 30, NSApp.isActive else { return }
        frameTimes.append(lastFrameMs)
        if frameTimes.count > 240 { frameTimes.removeFirst(frameTimes.count - 240) }
        worstFrameMs = frameTimes.max() ?? 0
    }

    func resetStats() {
        frameTimes.removeAll()
        gpuTimes.removeAll()
        framesSeen = 0
        worstFrameMs = 0
        worstGpuMs = 0
    }
}
