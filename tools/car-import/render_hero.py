"""Render a car for its loading screen: front three-quarter, transparent.

    Blender -b --factory-startup -P render_hero.py -- recipe.json out.png

Uses the recipe's source, drop list, nose direction and colour overrides;
materials named by the recipe's "hero_metallic" regexes render as metallic
paint. compose_loading.py lays the result over the MM3 loading screen.
"""
import bpy, json, math, mathutils, os, re, sys

args = sys.argv[sys.argv.index("--") + 1:]
recipe_path, out = args[0], args[1]
recipe = json.load(open(recipe_path))
base = os.path.dirname(os.path.abspath(recipe_path))
source = os.path.join(base, os.path.expanduser(recipe["source"]))

ext = os.path.splitext(source)[1].lower()
if ext == ".blend":
    bpy.ops.wm.open_mainfile(filepath=source)
else:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    (bpy.ops.import_scene.fbx if ext == ".fbx" else bpy.ops.import_scene.gltf)(filepath=source)
sc = bpy.context.scene
for o in list(sc.objects):
    if o.type in ("CAMERA", "LIGHT"):
        bpy.data.objects.remove(o)
        continue
    if o.type != "MESH":
        continue
    mats = " ".join(s.material.name for s in o.material_slots if s.material)
    label = f"{o.name} {o.data.name} {mats}"
    if any(re.search(p, label, re.I) for p in recipe.get("drop", [])):
        bpy.data.objects.remove(o)

# The recipe's scale (a model authored in centimetres), applied to the roots.
scale = recipe.get("scale", 1.0)
if scale != 1.0:
    for o in sc.objects:
        if o.parent is None:
            o.scale = [x * scale for x in o.scale]
            o.location = [x * scale for x in o.location]
    bpy.context.view_layer.update()

def linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

for m in bpy.data.materials:
    if not m.use_nodes:
        continue
    for n in m.node_tree.nodes:
        if n.type != "BSDF_PRINCIPLED":
            continue
        for pattern, colour in recipe.get("colors", {}).items():
            if re.search(pattern, m.name, re.I):
                for l in list(n.inputs["Base Color"].links):
                    m.node_tree.links.remove(l)
                n.inputs["Base Color"].default_value = [linear(c) for c in colour[:3]] + [1]
        if any(re.search(p, m.name, re.I) for p in recipe.get("hero_metallic", [])):
            for key, value in (("Metallic", 0.85), ("Roughness", 0.25)):
                for l in list(n.inputs[key].links):
                    m.node_tree.links.remove(l)
                n.inputs[key].default_value = value

pts = [o.matrix_world @ mathutils.Vector(c) for o in sc.objects if o.type == "MESH" for c in o.bound_box]
lo = mathutils.Vector([min(p[i] for p in pts) for i in range(3)])
hi = mathutils.Vector([max(p[i] for p in pts) for i in range(3)])
ctr, size = (lo + hi) / 2, (hi - lo).length

# Nose and right-hand directions in Blender space, from the recipe's forward axis.
nose = {"+Y": (0, 1, 0), "-Y": (0, -1, 0), "+X": (1, 0, 0), "-X": (-1, 0, 0)}[recipe.get("forward", "+Y")]
nose = mathutils.Vector(nose)
side = nose.cross(mathutils.Vector((0, 0, 1)))   # the car's right-hand side
cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
sc.collection.objects.link(cam)
sc.camera = cam
cam.data.lens = 32
cam.data.clip_end = size * 20
cam.location = ctr + (nose * 5.0 + side * 3.9) * (size / 6.3) + mathutils.Vector((0, 0, -0.15 * size / 6.3))
aim = ctr - nose * 0.2 * size / 6.3 + side * 0.35 * size / 6.3 - mathutils.Vector((0, 0, 0.25 * size / 6.3))
cam.rotation_euler = (aim - cam.location).to_track_quat("-Z", "Y").to_euler()

w = bpy.data.worlds.new("w")
sc.world = w
w.use_nodes = True
w.node_tree.nodes["Background"].inputs[0].default_value = (0.18, 0.24, 0.45, 1)
w.node_tree.nodes["Background"].inputs[1].default_value = 1.2
for offset, energy in ((nose * 6 + side * 4 + mathutils.Vector((0, 0, 5)), 900),
                       (nose * 2 - side * 5 + mathutils.Vector((0, 0, 4)), 500),
                       (-nose * 6 + mathutils.Vector((0, 0, 6)), 400)):
    light = bpy.data.objects.new("L", bpy.data.lights.new("L", "AREA"))
    light.data.energy, light.data.size = energy * (size / 6.3) ** 2, 4 * size / 6.3
    light.location = ctr + offset * (size / 6.3)
    light.rotation_euler = (ctr - light.location).to_track_quat("-Z", "Y").to_euler()
    sc.collection.objects.link(light)

engines = [e.identifier for e in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items]
sc.render.engine = "BLENDER_EEVEE_NEXT" if "BLENDER_EEVEE_NEXT" in engines else "BLENDER_EEVEE"
sc.render.film_transparent = True
sc.render.resolution_x, sc.render.resolution_y = 1280, 960
sc.view_settings.view_transform = "Standard"
sc.render.filepath = out
bpy.ops.render.render(write_still=True)
