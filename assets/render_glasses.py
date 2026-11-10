"""Turntable of the glasses for the README, and a .glb anyone can open.

    /Applications/Blender.app/Contents/MacOS/Blender -b -P assets/render_glasses.py
    then assets/make_pictures.sh

Same geometry as Iris/GlassesModelView.swift (SceneKit units, Y up), built under a root that turns it
Z-up and scales it to about 13 cm wide. Frames land in .build/turntable/, the model in assets/.
"""
import math
import sys
from pathlib import Path

import bpy

ROOT = Path(__file__).resolve().parent.parent
FRAMES = ROOT / ".build" / "turntable"
N = 120                      # one turn: 10 s at 12 fps
ACCENT = (1.0, 0.357, 0.122, 1)  # FF5B1F

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def material(name, color, rough, metal=0.0, clearcoat=0.0, alpha=1.0, emit=None):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    p = m.node_tree.nodes["Principled BSDF"]
    p.inputs["Base Color"].default_value = color
    p.inputs["Roughness"].default_value = rough
    p.inputs["Metallic"].default_value = metal
    p.inputs["Clearcoat"].default_value = clearcoat
    p.inputs["Alpha"].default_value = alpha
    if emit:
        p.inputs["Emission"].default_value = emit
        p.inputs["Emission Strength"].default_value = 1.6
    if alpha < 1:
        m.blend_method = "BLEND"
        m.shadow_method = "HASHED"
    return m


FRAME = material("Frame", (0.012, 0.012, 0.014, 1), 0.22, clearcoat=1.0)
LENS = material("Lens", (0.05, 0.05, 0.06, 1), 0.04, alpha=0.35)
LENS_DARK = material("Camera", (0.0, 0.0, 0.0, 1), 0.08, clearcoat=1.0)
LED = material("LED", ACCENT, 0.3, emit=ACCENT)

root = bpy.data.objects.new("Iris L801", None)
scene.collection.objects.link(root)
root.rotation_euler = (math.pi / 2, 0, 0)   # SceneKit Y-up → Blender Z-up
root.scale = (0.01, 0.01, 0.01)


def link(obj, mat):
    scene.collection.objects.link(obj)
    obj.parent = root
    obj.data.materials.append(mat)
    return obj


def rounded_rect(w, h, r, steps=10):
    pts = []
    for cx, cy, a0 in ((w / 2 - r, h / 2 - r, 0), (-w / 2 + r, h / 2 - r, 90),
                       (-w / 2 + r, -h / 2 + r, 180), (w / 2 - r, -h / 2 + r, 270)):
        for i in range(steps + 1):
            a = math.radians(a0 + 90 * i / steps)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def extruded(name, loops, depth, bevel, mat, loc):
    """2D curve whose inner loops become holes, extruded along SceneKit Z (centred, like SCNShape)."""
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "2D"
    cu.fill_mode = "BOTH"
    cu.extrude = depth / 2 - bevel
    cu.bevel_depth = bevel
    cu.bevel_resolution = 2
    for loop in loops:
        sp = cu.splines.new("POLY")
        sp.points.add(len(loop) - 1)
        for p, (x, y) in zip(sp.points, loop):
            p.co = (x, y, 0, 1)
        sp.use_cyclic_u = True
    obj = link(bpy.data.objects.new(name, cu), mat)
    obj.location = loc
    return obj


def box(name, w, h, d, loc, rot_x=0.0):
    me = bpy.data.meshes.new(name)
    x, y, z = w / 2, h / 2, d / 2
    v = [(sx * x, sy * y, sz * z) for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
    me.from_pydata(v, [], [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)])
    obj = link(bpy.data.objects.new(name, me), FRAME)
    obj.location, obj.rotation_euler = loc, (rot_x, 0, 0)
    bev = obj.modifiers.new("chamfer", "BEVEL")
    bev.width, bev.segments = min(w, h) * 0.3, 3
    obj.modifiers.new("smooth", "WEIGHTED_NORMAL")
    me.use_auto_smooth = True
    return obj


for side in (-1, 1):
    x = 3.45 * side
    extruded(f"Rim {side}", [rounded_rect(5.8, 4.6, 1.7), rounded_rect(4.7, 3.5, 1.2)], 0.55, 0.06, FRAME, (x, 0, 0))
    extruded(f"Lens {side}", [rounded_rect(5.0, 3.9, 1.4)], 0.12, 0.02, LENS, (x, 0, 0))
    t = 6.15 * side
    box(f"Hinge {side}", 0.6, 0.95, 0.7, (t, 1.25, -0.3))
    box(f"Temple front {side}", 0.5, 0.95, 5.4, (t, 1.25, -3.3))
    box(f"Temple back {side}", 0.34, 0.55, 5.0, (t, 1.2, -8.5))
    box(f"Temple tip {side}", 0.34, 0.5, 2.2, (t, 1.2 - 1.1 * math.sin(0.6), -11 - 1.1 * math.cos(0.6)), -0.6)

# Bridge: an arc of radius 0.85 from 0.15π to 0.85π, 0.4 thick.
arc = [(0.85 + s * 0.2) for s in (1, -1)]
outer = [(arc[0] * math.cos(a), arc[0] * math.sin(a)) for a in (math.pi * (0.15 + 0.7 * i / 16) for i in range(17))]
inner = [(arc[1] * math.cos(a), arc[1] * math.sin(a)) for a in (math.pi * (0.85 - 0.7 * i / 16) for i in range(17))]
extruded("Bridge", [outer + inner], 0.45, 0.05, FRAME, (0, 0.75, 0))

bpy.ops.mesh.primitive_cylinder_add(radius=0.3, depth=0.25, vertices=48)
cam_lens = bpy.context.object
cam_lens.name = "Camera"
cam_lens.parent, cam_lens.location, cam_lens.rotation_euler = root, (5.75, 1.3, 0.38), (math.pi / 2, 0, 0)
cam_lens.data.materials.append(LENS_DARK)
bpy.ops.mesh.primitive_uv_sphere_add(radius=0.14, segments=24, ring_count=12)
led = bpy.context.object
led.name = "LED"
led.parent, led.location = root, (-5.75, 1.3, 0.36)
led.data.materials.append(LED)
bpy.ops.object.shade_smooth()

# --- light and camera ----------------------------------------------------------

world = bpy.data.worlds.new("World")
scene.world = world
world.use_nodes = True
bg = world.node_tree.nodes["Background"]
bg.inputs["Color"].default_value = (0.5, 0.5, 0.52, 1)
bg.inputs["Strength"].default_value = 0.8

for name, energy, rot in (("Key", 4.0, (math.radians(50), 0, math.radians(-40))),
                          ("Rim", 3.0, (math.radians(-60), 0, math.radians(160))),
                          ("Top", 1.5, (0, 0, 0))):
    light = bpy.data.objects.new(name, bpy.data.lights.new(name, "SUN"))
    light.data.energy, light.data.angle = energy, math.radians(8)
    light.rotation_euler = rot
    scene.collection.objects.link(light)

cam = bpy.data.objects.new("Camera", bpy.data.cameras.new("Camera"))
scene.collection.objects.link(cam)
cam.data.type, cam.data.ortho_scale = "ORTHO", 0.26
cam.location = (0, -1, 0.16)                        # a little above, like the app's 0.16 tilt
cam.rotation_euler = (math.pi / 2 - 0.16, 0, 0)
scene.camera = cam

# Turntable: spin the model about its own centre (temples reach back to z ≈ -12).
pivot = bpy.data.objects.new("Pivot", None)
scene.collection.objects.link(pivot)
pivot.location = (0, 0.06, 0)
root.parent = pivot
root.location = (0, -0.06, 0)
pivot.rotation_euler = (0, 0, math.radians(-25))
pivot.keyframe_insert("rotation_euler", index=2, frame=1)
pivot.rotation_euler[2] += 2 * math.pi
pivot.keyframe_insert("rotation_euler", index=2, frame=N + 1)
for fc in pivot.animation_data.action.fcurves:
    for k in fc.keyframe_points:
        k.interpolation = "LINEAR"

scene.frame_start, scene.frame_end = 1, N
scene.render.engine = "BLENDER_EEVEE"
scene.eevee.taa_render_samples = 48
scene.eevee.use_ssr = True
scene.eevee.use_gtao = True
scene.eevee.use_soft_shadows = True
scene.view_settings.view_transform = "Filmic"
scene.view_settings.look = "Medium High Contrast"
scene.render.resolution_x, scene.render.resolution_y = 840, 460
scene.render.film_transparent = True
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.render.filepath = str(FRAMES / "f_")

if "still" in sys.argv:      # quick look: one frame, no model
    scene.frame_set(8)
    scene.render.filepath = str(FRAMES.parent / "still.png")
    bpy.ops.render.render(write_still=True)
    sys.exit()
bpy.ops.render.render(animation=True)

# --- model ---------------------------------------------------------------------

pivot.animation_data_clear()
pivot.rotation_euler = (0, 0, 0)
for obj in [o for o in scene.objects if o.type == "CURVE"]:
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.convert(target="MESH")
bpy.ops.object.select_all(action="DESELECT")
for obj in scene.objects:
    obj.select_set(obj.type in {"MESH", "EMPTY"})
bpy.ops.export_scene.gltf(filepath=str(ROOT / "assets" / "iris-glasses.glb"), export_format="GLB",
                          use_selection=True, export_apply=True)
