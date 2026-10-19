"""Export a glTF/GLB/FBX/.blend car as the neutral model.json build_package.py reads.

Run inside Blender:
    Blender -b --factory-startup -P blender_source.py -- recipe.json out_dir

The recipe names the source file and how to sort its parts:
    {
      "source": "car.glb", "name": "porsche_930_turbo",
      "drop": ["coat", "ground"],          # material/object name regexes to leave out
      "wheel": ["rim", "tire"],            # material/object regexes for wheel parts
      "headlight": ["lights"], "taillight": ["lights"],   # lamp parts, split front/rear
      "body_tris": 30000, "wheel_tris": 6000,
      "scale": 1.0, "forward": "+Y"        # Blender axis the car's nose points along
    }

Output: out_dir/model.json and out_dir/textures/*.png, in the neutral
coordinates (+Y up, -Z forward, metres, top-left UVs, column transforms):
BODY_H, WHL0_H..WHL3_H (front-left, front-right, rear-left, rear-right, each
around its own pivot) and HLIGHT_H / TLIGHT_H lamp helpers.
"""
import bpy, bmesh, json, math, os, re, sys
from mathutils import Matrix, Vector

args = sys.argv[sys.argv.index("--") + 1:]
recipe_path, out_dir = args[0], args[1]
recipe = json.load(open(recipe_path))
base = os.path.dirname(os.path.abspath(recipe_path))
source = os.path.join(base, os.path.expanduser(recipe["source"]))

def matches(name, patterns):
    return any(re.search(p, name, re.I) for p in patterns)

# --- load -------------------------------------------------------------------
ext = os.path.splitext(source)[1].lower()
if ext == ".blend":
    bpy.ops.wm.open_mainfile(filepath=source)
else:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    if ext == ".fbx":
        bpy.ops.import_scene.fbx(filepath=source)
    else:
        bpy.ops.import_scene.gltf(filepath=source)
scene = bpy.context.scene

# Blender world -> neutral: nose along recipe["forward"] becomes -Z, Blender Z
# becomes +Y. Both are proper rotations, so winding and normals carry over.
fwd = recipe.get("forward", "+Y")
rot = {"+Y": Matrix(((1, 0, 0), (0, 0, 1), (0, -1, 0))),
       "-Y": Matrix(((-1, 0, 0), (0, 0, 1), (0, 1, 0))),
       "+X": Matrix(((0, -1, 0), (0, 0, 1), (-1, 0, 0))),
       "-X": Matrix(((0, 1, 0), (0, 0, 1), (1, 0, 0)))}[fwd].to_4x4()
to_neutral = rot @ Matrix.Scale(recipe.get("scale", 1.0), 4)

# --- classify mesh objects --------------------------------------------------
drop, wheel_p = recipe.get("drop", []), recipe.get("wheel", [])
head_p, tail_p = recipe.get("headlight", []), recipe.get("taillight", [])
dg = bpy.context.evaluated_depsgraph_get()

def object_label(o):
    mats = " ".join(s.material.name for s in o.material_slots if s.material)
    return f"{o.name} {o.data.name} {mats}"

def world_mesh(o):
    """A triangulated bmesh of the evaluated object in neutral coordinates."""
    me = o.evaluated_get(dg).to_mesh()
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.transform(to_neutral @ o.matrix_world)
    if (to_neutral @ o.matrix_world).determinant() < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    bmesh.ops.triangulate(bm, faces=bm.faces)
    mats = [s.material for s in o.material_slots]
    o.evaluated_get(dg).to_mesh_clear()
    return bm, mats

parts = {"body": [], "wheel": [], "head": [], "tail": []}
for o in scene.objects:
    if o.type != "MESH" or not o.visible_get():
        continue
    label = object_label(o)
    if matches(label, drop):
        continue
    if matches(label, wheel_p):
        parts["wheel"].append(o)
        continue
    parts["body"].append(o)

# --- geometry helpers ---------------------------------------------------------
def bm_center(bm):
    vs = [v.co for v in bm.verts]
    lo = Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs)))
    hi = Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
    return (lo + hi) / 2, lo, hi

def merge(objs):
    """One bmesh of several objects; materials remapped into one list."""
    out, out_mats = bmesh.new(), []
    uv_out = out.loops.layers.uv.new("uv")
    for o in objs:
        bm, mats = world_mesh(o)
        uv_in = bm.loops.layers.uv.active
        index = []
        for m in mats or [None]:
            if m not in out_mats:
                out_mats.append(m)
            index.append(out_mats.index(m))
        vmap = {v: out.verts.new(v.co) for v in bm.verts}
        for f in bm.faces:
            try:
                nf = out.faces.new([vmap[v] for v in f.verts])
            except ValueError:
                continue
            nf.material_index = index[min(f.material_index, len(index) - 1)]
            nf.smooth = f.smooth
            for la, lb in zip(f.loops, nf.loops):
                lb[uv_out].uv = la[uv_in].uv if uv_in else (0.5, 0.5)
        bm.free()
    return out, out_mats

def decimate(bm, target):
    tris = len(bm.faces)
    if tris <= target:
        return bm
    me = bpy.data.meshes.new("tmp")
    bm.to_mesh(me)
    ob = bpy.data.objects.new("tmp", me)
    scene.collection.objects.link(ob)
    mod = ob.modifiers.new("dec", "DECIMATE")
    mod.ratio = target / tris
    mod.use_collapse_triangulate = True
    d2 = bpy.context.evaluated_depsgraph_get()
    em = ob.evaluated_get(d2).to_mesh()
    out = bmesh.new()
    out.from_mesh(em)
    bmesh.ops.triangulate(out, faces=out.faces)
    ob.evaluated_get(d2).to_mesh_clear()
    bpy.data.objects.remove(ob)
    bm.free()
    return out

# --- materials and textures ---------------------------------------------------
os.makedirs(os.path.join(out_dir, "textures"), exist_ok=True)
materials, mat_index = [], {}

def base_color_image(mat):
    if not mat or not mat.use_nodes:
        return None
    for node in mat.node_tree.nodes:
        if node.type == "BSDF_PRINCIPLED":
            sock = node.inputs["Base Color"]
            seen, todo = set(), [sock]
            while todo:
                s = todo.pop()
                for link in s.links:
                    n = link.from_node
                    if n.type == "TEX_IMAGE" and n.image:
                        return n.image
                    if n.name not in seen:
                        seen.add(n.name)
                        todo.extend(i for i in n.inputs if i.is_linked)
    return None

def principled(mat):
    if mat and mat.use_nodes:
        for node in mat.node_tree.nodes:
            if node.type == "BSDF_PRINCIPLED":
                return node
    return None

def srgb(c):
    """Blender colour values are linear; the neutral model's are display values."""
    return c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055

def material_id(mat):
    if mat in mat_index:
        return mat_index[mat]
    name = mat.name if mat else "untextured"
    record = {"name": name, "texture": None, "diffuse": [0.8, 0.8, 0.8, 1.0]}
    p = principled(mat)
    if p:
        c = p.inputs["Base Color"].default_value
        alpha = p.inputs["Alpha"].default_value
        record["diffuse"] = [srgb(c[0]), srgb(c[1]), srgb(c[2]), alpha]
        rough = p.inputs["Roughness"].default_value
        record["shininess"] = round(max(0.0, 1.0 - rough) * 0.5, 3)
        if p.inputs["Transmission Weight"].default_value > 0.5 if "Transmission Weight" in p.inputs else False:
            record["diffuse"][3] = min(alpha, 0.35)
    elif mat:
        record["diffuse"] = list(mat.diffuse_color)
    image = base_color_image(mat)
    if image:
        fname = re.sub(r"[^A-Za-z0-9_.-]", "_", image.name)
        fname = os.path.splitext(fname)[0] + ".png"
        path = os.path.join(out_dir, "textures", fname)
        if not os.path.exists(path):
            img = image.copy()
            limit = recipe.get("texture_limit", 2048)
            w, h = img.size
            if max(w, h) > limit:
                s = limit / max(w, h)
                img.scale(max(1, int(w * s)), max(1, int(h * s)))
            if matches(name, recipe.get("opaque_textures", [])):
                # Detail stored under transparent texels (lamp lenses) would be
                # baked over black by the package builder; keep it opaque.
                px = list(img.pixels)
                px[3::4] = [1.0] * (len(px) // 4)
                img.pixels[:] = px
            img.filepath_raw = path
            img.file_format = "PNG"
            img.save()
            bpy.data.images.remove(img)
        record["texture"] = "textures/" + fname
        record["diffuse"] = [1.0, 1.0, 1.0, record["diffuse"][3]]
    for pattern, colour in recipe.get("colors", {}).items():
        if re.search(pattern, name, re.I):   # display-value RGB(A) override
            record["texture"] = None
            record["diffuse"] = list(colour) + record["diffuse"][len(colour):]
    mat_index[mat] = len(materials)
    materials.append(record)
    return mat_index[mat]

def mesh_record(name, bm, mats, pivot):
    uv = bm.loops.layers.uv.active
    positions, normals, uvs, triangles, key = [], [], [], [], {}
    for f in bm.faces:
        mid = material_id(mats[f.material_index] if f.material_index < len(mats) else None)
        corners = []
        for loop in f.loops:
            co = loop.vert.co - pivot
            n = loop.vert.normal if f.smooth else f.normal
            t = loop[uv].uv if uv else Vector((0.5, 0.5))
            k = (tuple(round(x, 5) for x in co), tuple(round(x, 3) for x in n),
                 round(t.x, 5), round(t.y, 5))
            if k not in key:
                key[k] = len(positions)
                positions.append([co.x, co.y, co.z])
                normals.append([n.x, n.y, n.z])
                uvs.append([t.x, 1.0 - t.y])
            corners.append(key[k])
        if len(corners) == 3:
            triangles.append(corners + [mid])
    transform = [[1, 0, 0, pivot.x], [0, 1, 0, pivot.y], [0, 0, 1, pivot.z], [0, 0, 0, 1]]
    return {"name": name, "part": name[:-2], "lod": "H", "positions": positions,
            "normals": normals, "uvs": uvs, "triangles": triangles, "transform": transform}

# --- wheels: four corners -----------------------------------------------------
corners = {}
for o in parts["wheel"]:
    bm, _ = world_mesh(o)
    c, _, _ = bm_center(bm)
    bm.free()
    corners.setdefault((c.x > 0, c.z > 0), []).append(o)
if len(corners) != 4:
    raise SystemExit(f"expected wheel parts at four corners, found {sorted(corners)}")

wheel_meshes, ground, axles = [], None, []
names = {(False, False): "WHL0_H", (True, False): "WHL1_H",
         (False, True): "WHL2_H", (True, True): "WHL3_H"}
built = {}
def straighten(bm, mats):
    """Turn a wheel modelled steered or cambered so its axle lies along X.

    The game spins and steers each wheel about its own axes; a wheel posed at
    an angle would wobble. The axle is the direction of least spread of the
    wheel's vertices (a wheel is a short, wide cylinder)."""
    import numpy as np
    tyre = recipe.get("tyre", r"tire|tyre")
    ids = {i for i, m in enumerate(mats) if m and re.search(tyre, m.name, re.I)}
    verts = {v for f in bm.faces if f.material_index in ids for v in f.verts} or set(bm.verts)
    pts = np.array([v.co[:] for v in verts])
    centre = (pts.min(0) + pts.max(0)) / 2
    w, vecs = np.linalg.eigh(np.cov((pts - pts.mean(0)).T))
    axle = Vector(vecs[:, 0])
    if axle.x < 0:
        axle = -axle
    turn = axle.rotation_difference(Vector((1, 0, 0))).to_matrix().to_4x4()
    about = Matrix.Translation(Vector(centre)) @ turn @ Matrix.Translation(-Vector(centre))
    bm.transform(about)
    bm.normal_update()
    return math.degrees(axle.angle(Vector((1, 0, 0))))

for corner, objs in corners.items():
    bm, mats = merge(objs)
    bm = decimate(bm, recipe.get("wheel_tris", 6000))
    print("WHEEL", names[corner], "straightened by %.1f degrees" % straighten(bm, mats))
    c, lo, hi = bm_center(bm)
    ground = lo.y if ground is None else min(ground, lo.y)
    built[corner] = (bm, mats, c)

# Lift so the tyres stand on y = 0 and centre the wheelbase on z = 0.
front_z = sum(built[k][2].z for k in built if not k[1]) / 2
rear_z = sum(built[k][2].z for k in built if k[1]) / 2
mid_x = sum(built[k][2].x for k in built) / 4
shift = Vector((-mid_x, -ground, -(front_z + rear_z) / 2))

def shifted(bm):
    bmesh.ops.translate(bm, verts=bm.verts, vec=shift)
    bm.normal_update()
    return bm

meshes = []
for corner, (bm, mats, c) in built.items():
    shifted(bm)
    meshes.append(mesh_record(names[corner], bm, mats, c + shift))
    bm.free()

# --- body and lamp helpers ----------------------------------------------------
body, body_mats = merge(parts["body"])
shifted(body)
body = decimate(body, recipe.get("body_tris", 30000))
body.normal_update()
meshes.insert(0, mesh_record("BODY_H", body, body_mats, Vector((0, 0, 0))))
body.free()

def lamps(patterns, rear):
    objs = [o for o in parts["body"] if matches(object_label(o), patterns)]
    if not objs:
        return None
    bm, mats = merge(objs)
    shifted(bm)
    keep = [f for f in bm.faces if (f.calc_center_median().z > 0) == rear]
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if f not in keep], context="FACES")
    if not bm.faces:
        bm.free()
        return None
    return bm, mats

for name, patterns, rear in (("HLIGHT_H", head_p, False), ("TLIGHT_H", tail_p, True)):
    got = lamps(patterns, rear)
    if got:
        bm, mats = got
        bm.normal_update()
        meshes.append(mesh_record(name, bm, mats, Vector((0, 0, 0))))
        bm.free()

model = {"version": 1, "name": recipe["name"], "source_format": "Blender " + ext,
         "coordinates": {"up": "+Y", "forward": "-Z", "units": "meters",
                         "uv_origin": "top_left", "transform_vectors": "columns"},
         "paintjob": 0, "paintjob_count": 1, "meshes": meshes, "materials": materials,
         "references": [], "offset": [0, 0, 0]}
with open(os.path.join(out_dir, "model.json"), "w") as f:
    json.dump(model, f, separators=(",", ":"))
for m in meshes:
    t = m["transform"]
    print("MESH", m["name"], len(m["triangles"]), "pivot",
          [round(t[i][3], 3) for i in range(3)])
print("MATERIALS", len(materials), [m["name"] for m in materials])
