import Foundation
import RealityKit
import simd

// MARK: - Camera
//
// A three-quarter isometric view looking down into the room, like the reference.
// Orthographic, so nothing changes size with depth and the name tags can be a
// fixed world size. A slow drift keeps the scene from feeling like a still;
// dragging orbits around the room and scrolling zooms, both clamped so the
// user cannot end up looking at the outside of a wall.

@MainActor
final class WorldCamera {
    let rig = Entity()          // at the room's focal point; yaw lives here
    private let pitch = Entity() // pitch lives here
    private let camera = PerspectiveCamera()

    private(set) var yaw: Float = .pi / 4          // radians, 45° = looking along the room's diagonal
    private(set) var tilt: Float = -0.62           // radians, ~35° down
    /// User zoom, 1 = the whole room framed.
    private(set) var zoom: Float = 1
    private var aspect: Float = 1
    private let distance: Float = 90
    /// Radius of the sphere the room has to fit in, at the focus.
    private let roomRadius: Float = 8.2
    /// Visible height in metres at the focus: fit the room's sphere in the
    /// narrower of the two view dimensions, then apply the user's zoom.
    private var visibleHeight: Float {
        let fit = roomRadius * 2 * 1.04
        return (aspect < 1 ? fit / aspect : fit) / zoom
    }
    private var fov: Float { 2 * atan(visibleHeight / 2 / distance) * 180 / .pi }

    private var userYawOffset: Float = 0
    private var driftTime: Float = 0
    private let driftAmplitude: Float = 0.035
    private let driftPeriod: Float = 46

    var focus: SIMD3<Float> {
        get { rig.position }
        set { rig.position = newValue }
    }

    init() {
        rig.name = "cameraRig"
        rig.addChild(pitch)
        pitch.addChild(camera)
        // A long, narrow lens far from the room reads as isometric: parallel
        // enough that a figure at the back is the size of one at the front.
        // ARView does not drive OrthographicCameraComponent, so this is the
        // orthographic look rather than the orthographic API.
        camera.camera.near = 1
        camera.camera.far = 400
        camera.camera.fieldOfViewInDegrees = fov
        camera.position = SIMD3(0, 0, distance)
        apply()
    }

    func tick(dt: Float) {
        driftTime += dt
        apply()
    }

    func orbit(byPixels dx: Float) {
        userYawOffset = max(-0.55, min(0.55, userYawOffset - dx * 0.004))
        apply()
    }

    func zoom(byScrollDelta dy: Float) {
        zoom = max(0.7, min(2.6, zoom * (1 + dy * 0.02)))
        camera.camera.fieldOfViewInDegrees = fov
    }

    func viewResized(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        aspect = Float(size.width / size.height)
        camera.camera.fieldOfViewInDegrees = fov
    }

    private func apply() {
        let drift = sin(driftTime / driftPeriod * 2 * .pi) * driftAmplitude
        rig.orientation = simd_quatf(angle: yaw + userYawOffset + drift, axis: SIMD3(0, 1, 0))
        pitch.orientation = simd_quatf(angle: tilt + cos(driftTime / driftPeriod * 2 * .pi) * 0.008,
                                       axis: SIMD3(1, 0, 0))
    }

    var worldPosition: SIMD3<Float> { camera.position(relativeTo: nil) }

    /// The camera's forward direction in world space, for anything that should
    /// face the viewer (a waiting agent turns to the camera).
    var forward: SIMD3<Float> {
        let m = camera.transformMatrix(relativeTo: nil)
        return -SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
    }
}
