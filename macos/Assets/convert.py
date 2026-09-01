"""Convert a glTF / GLB / FBX / OBJ model to USDZ for RealityKit, headlessly.

    tools/Blender.app/Contents/MacOS/Blender -b --python macos/Assets/convert.py -- \
        <input> <output.usdz> [options]

Options
    --scale S                uniform scale applied to every root object
    --recenter               move the model so it sits on y=0, centred on x/z
    --bake                   apply rotation and scale into the meshes (not for skinned rigs)
    --keep A,B,C             keep only objects whose name contains one of these
    --drop A,B,C             remove objects whose name contains one of these
    --color MAT=r,g,b        set a material's base colour (name match, case-insensitive)
    --emissive MAT=r,g,b,S   set a material's emission colour and strength
    --rename MAT=NEW         rename a material (so the app can find it by name)
    --action NAME            make this the active clip on every rig, export only it
    --strip-anim-prefix      rename actions "Armature|Walk" -> "Walk"
    --no-anim                do not export animation
    --selftest DIR           build a rigged test model, export GLB, convert it

RealityKit wants Y up, -Z forward, metres, and skeletal animation in UsdSkel.
Blender's USD exporter produces all of that; the kwargs it accepts shift a little
between releases, so unknown ones are dropped and the export retried rather than
pinning this script to one Blender.

Prints one line "bbox: <min> <max>" after any scale/recentre so the driver can
sanity-check sizes without opening the result.
"""
import math
import os
import re
import sys

import bpy
from mathutils import Vector

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def log(msg):
    print("convert: " + msg, flush=True)


def opt(name, default=None):
    if name in ARGS:
        i = ARGS.index(name)
        return ARGS[i + 1] if i + 1 < len(ARGS) else default
    return default


def opts(name):
    """All values of a repeatable option."""
    out = []
    for i, a in enumerate(ARGS):
        if a == name and i + 1 < len(ARGS):
            out.append(ARGS[i + 1])
    return out


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def import_model(path):
    ext = os.path.splitext(path)[1].lower()
    if ext in (".glb", ".gltf"):
        bpy.ops.import_scene.gltf(filepath=path)
    elif ext == ".fbx":
        bpy.ops.import_scene.fbx(filepath=path)
    elif ext == ".obj":
        bpy.ops.wm.obj_import(filepath=path)
    elif ext in (".usd", ".usda", ".usdc", ".usdz"):
        bpy.ops.wm.usd_import(filepath=path)
    else:
        raise SystemExit("unsupported input: " + path)


def roots():
    return [o for o in bpy.data.objects if o.parent is None]


def meshes():
    return [o for o in bpy.data.objects if o.type == "MESH"]


def world_bbox():
    lo = Vector((math.inf,) * 3)
    hi = Vector((-math.inf,) * 3)
    dg = bpy.context.evaluated_depsgraph_get()
    for o in meshes():
        ev = o.evaluated_get(dg)
        for c in ev.bound_box:
            p = ev.matrix_world @ Vector(c)
            lo = Vector(map(min, lo, p))
            hi = Vector(map(max, hi, p))
    return lo, hi


def filter_objects(keep, drop):
    def matches(o, terms):
        n = o.name.lower()
        return any(t.lower() in n for t in terms)

    def subtree_matches(o, terms):
        return matches(o, terms) or any(subtree_matches(c, terms) for c in o.children)

    if keep:
        for o in list(bpy.data.objects):
            # keep an object if it or anything below it matches, or if it is an
            # ancestor of a match (armatures, empties)
            if not subtree_matches(o, keep) and not any(matches(a, keep) for a in ancestors(o)):
                bpy.data.objects.remove(o, do_unlink=True)
    if drop:
        for o in list(bpy.data.objects):
            if matches(o, drop):
                bpy.data.objects.remove(o, do_unlink=True)


def ancestors(o):
    out = []
    p = o.parent
    while p:
        out.append(p)
        p = p.parent
    return out


def apply_scale(scale):
    if scale == 1.0:
        return
    for o in roots():
        o.scale = (o.scale[0] * scale, o.scale[1] * scale, o.scale[2] * scale)
    bpy.context.view_layer.update()


def bake():
    """Apply rotation and scale into mesh data. Skips rigs, where applying
    object transforms would silently break the skin binding."""
    if any(o.type == "ARMATURE" for o in bpy.data.objects):
        log("rig present, not baking transforms")
        return
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes():
        o.select_set(True)
    if bpy.context.selected_objects:
        bpy.context.view_layer.objects.active = bpy.context.selected_objects[0]
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)


def recenter():
    lo, hi = world_bbox()
    if not all(map(math.isfinite, list(lo) + list(hi))):
        return
    # Blender is Z up here; the exporter converts to Y up
    cx, cy = (lo.x + hi.x) / 2, (lo.y + hi.y) / 2
    shift = Vector((-cx, -cy, -lo.z))
    for o in roots():
        o.location = o.location + shift
    bpy.context.view_layer.update()


def find_materials(term):
    t = term.lower()
    return [m for m in bpy.data.materials if t in m.name.lower()]


def principled(mat):
    if not mat.use_nodes:
        mat.use_nodes = True
    for n in mat.node_tree.nodes:
        if n.type == "BSDF_PRINCIPLED":
            return n
    n = mat.node_tree.nodes.new("ShaderNodeBsdfPrincipled")
    out = next((x for x in mat.node_tree.nodes if x.type == "OUTPUT_MATERIAL"), None)
    if out:
        mat.node_tree.links.new(n.outputs["BSDF"], out.inputs["Surface"])
    return n


def set_color(spec):
    name, rgb = spec.split("=")
    r, g, b = (float(x) for x in rgb.split(","))
    mats = find_materials(name)
    if not mats:
        log("WARNING no material matches '%s' (have: %s)" % (name, ", ".join(m.name for m in bpy.data.materials)))
    for m in mats:
        node = principled(m)
        # drop any texture feeding base colour so the flat colour wins
        for l in list(m.node_tree.links):
            if l.to_node == node and l.to_socket.name == "Base Color":
                m.node_tree.links.remove(l)
        node.inputs["Base Color"].default_value = (r, g, b, 1)
        log("colour %s -> %.2f %.2f %.2f" % (m.name, r, g, b))


def set_emissive(spec):
    name, vals = spec.split("=")
    r, g, b, s = (float(x) for x in vals.split(","))
    mats = find_materials(name)
    if not mats:
        log("WARNING no material matches '%s' for emissive" % name)
    for m in mats:
        node = principled(m)
        emis = node.inputs.get("Emission Color") or node.inputs.get("Emission")
        emis.default_value = (r, g, b, 1)
        node.inputs["Emission Strength"].default_value = s
        log("emissive %s -> %.2f %.2f %.2f x%.1f" % (m.name, r, g, b, s))


def rename_material(spec):
    old, new = spec.split("=")
    mats = find_materials(old)
    if not mats:
        log("WARNING no material matches '%s' to rename" % old)
    for m in mats:
        log("material %s -> %s" % (m.name, new))
        m.name = new


def select_action(name):
    """Blender's USD exporter writes each armature's active action and nothing
    else, so a character with many clips is exported once per clip."""
    matches = [a for a in bpy.data.actions if a.name.lower() == name.lower()] or \
              [a for a in bpy.data.actions if name.lower() in a.name.lower()]
    if not matches:
        raise SystemExit("no action matches '%s' (have: %s)" % (name, ", ".join(a.name for a in bpy.data.actions)))
    action = matches[0]
    for o in bpy.data.objects:
        if o.type == "ARMATURE":
            if o.animation_data is None:
                o.animation_data_create()
            o.animation_data.action = action
            try:
                if getattr(action, "slots", None) and len(action.slots) and not o.animation_data.action_slot:
                    o.animation_data.action_slot = action.slots[0]
            except Exception as e:  # older API
                log("slot assignment skipped: %s" % e)
    start, end = action.frame_range
    bpy.context.scene.frame_start = int(start)
    bpy.context.scene.frame_end = int(end)
    for a in list(bpy.data.actions):
        if a is not action:
            bpy.data.actions.remove(a)
    log("active action %s frames %d-%d" % (action.name, start, end))


def strip_anim_prefix():
    for a in bpy.data.actions:
        if "|" in a.name:
            new = a.name.split("|", 1)[1]
            log("action %s -> %s" % (a.name, new))
            a.name = new


def export_usdz(path, animation=True):
    kwargs = dict(
        filepath=path,
        export_animation=animation,
        export_armatures=animation,
        export_shapekeys=True,
        only_deform_bones=False,
        export_materials=True,
        export_uvmaps=True,
        export_normals=True,
        export_mesh_colors=True,
        generate_preview_surface=True,
        convert_orientation=True,
        export_global_forward_selection="NEGATIVE_Z",
        export_global_up_selection="Y",
        use_instancing=False,
        evaluation_mode="RENDER",
        root_prim_path="/root",
        export_lights=False,
        export_cameras=False,
        relative_paths=True,
        export_textures_mode="NEW",
        triangulate_meshes=False,
        convert_scene_units="METERS",
    )
    for _ in range(len(kwargs)):
        try:
            bpy.ops.wm.usd_export(**kwargs)
            return
        except TypeError as e:
            m = re.search(r'keyword "(\w+)" unrecognized', str(e)) or re.search(r"'(\w+)'", str(e))
            if not m or m.group(1) not in kwargs:
                raise
            kwargs.pop(m.group(1))
    bpy.ops.wm.usd_export(**kwargs)


def convert(src, dst):
    reset()
    import_model(src)
    filter_objects([t for s in opts("--keep") for t in s.split(",")],
                   [t for s in opts("--drop") for t in s.split(",")])
    if "--bake" in ARGS:
        bake()
    apply_scale(float(opt("--scale", "1")))
    if "--recenter" in ARGS:
        recenter()
    for spec in opts("--color"):
        set_color(spec)
    for spec in opts("--emissive"):
        set_emissive(spec)
    for spec in opts("--rename"):
        rename_material(spec)
    if "--strip-anim-prefix" in ARGS:
        strip_anim_prefix()
    if opt("--action"):
        select_action(opt("--action"))
    lo, hi = world_bbox()
    # report in Y-up terms, as RealityKit will see it: blender (x, y, z) -> (x, z, -y)
    log("bbox: x[%.2f %.2f] y[%.2f %.2f] z[%.2f %.2f]" % (lo.x, hi.x, lo.z, hi.z, -hi.y, -lo.y))
    log("materials: " + ", ".join(m.name for m in bpy.data.materials))
    if bpy.data.actions:
        log("actions: " + ", ".join(a.name for a in bpy.data.actions))
    os.makedirs(os.path.dirname(os.path.abspath(dst)), exist_ok=True)
    if os.path.exists(dst):
        os.remove(dst)
    export_usdz(dst, animation="--no-anim" not in ARGS)
    if not os.path.exists(dst):
        raise SystemExit("export produced nothing: " + dst)
    log("wrote %s (%d KB)" % (dst, os.path.getsize(dst) // 1024))


def selftest(outdir):
    """A cylinder skinned to a one-bone armature that bends over 24 frames,
    plus a cube with keyframed object rotation, exported to GLB and back."""
    os.makedirs(outdir, exist_ok=True)
    reset()
    scene = bpy.context.scene
    scene.frame_start, scene.frame_end = 1, 24
    coll = bpy.context.collection
    arm = bpy.data.armatures.new("Arm")
    armobj = bpy.data.objects.new("Arm", arm)
    coll.objects.link(armobj)
    bpy.context.view_layer.objects.active = armobj
    bpy.ops.object.mode_set(mode="EDIT")
    b = arm.edit_bones.new("Bone")
    b.head, b.tail = (0, 0, 0), (0, 0, 1)
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.mesh.primitive_cylinder_add(radius=0.2, depth=1, location=(0, 0, 0.5), vertices=12)
    cyl = bpy.context.active_object
    cyl.name = "Body"
    vg = cyl.vertex_groups.new(name="Bone")
    vg.add(list(range(len(cyl.data.vertices))), 1.0, "REPLACE")
    mod = cyl.modifiers.new("Arm", "ARMATURE")
    mod.object = armobj
    cyl.parent = armobj
    mat = bpy.data.materials.new("Hoodie")
    mat.use_nodes = True
    mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.85, 0.47, 0.34, 1)
    cyl.data.materials.append(mat)
    pb = armobj.pose.bones["Bone"]
    pb.rotation_mode = "XYZ"
    for frame, rot in ((1, 0.0), (12, 0.8), (24, 0.0)):
        pb.rotation_euler = (rot, 0, 0)
        pb.keyframe_insert(data_path="rotation_euler", frame=frame)
    armobj.animation_data.action.name = "Bend"
    bpy.ops.mesh.primitive_cube_add(size=0.3, location=(1, 0, 0.15))
    cube = bpy.context.active_object
    cube.name = "Spinner"
    for frame, z in ((1, 0.0), (24, 6.283)):
        cube.rotation_euler = (0, 0, z)
        cube.keyframe_insert(data_path="rotation_euler", frame=frame)
    glb = os.path.join(outdir, "selftest.glb")
    bpy.ops.export_scene.gltf(filepath=glb, export_format="GLB", export_animations=True,
                              export_skins=True, export_apply=False)
    log("selftest glb %d KB" % (os.path.getsize(glb) // 1024))
    convert(glb, os.path.join(outdir, "selftest.usdz"))


def main():
    if "--selftest" in ARGS:
        selftest(opt("--selftest"))
        return
    positional = [a for i, a in enumerate(ARGS) if not a.startswith("--")
                  and (i == 0 or not ARGS[i - 1].startswith("--") or ARGS[i - 1] in ("--recenter", "--bake", "--strip-anim-prefix", "--no-anim"))]
    if len(positional) < 2:
        raise SystemExit(__doc__)
    convert(positional[0], positional[1])


main()
