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
    """One bmesh of several objects; materials remapped into one list.
    An item may be (object, face indices) to take only those faces."""
    out, out_mats = bmesh.new(), []
    uv_out = out.loops.layers.uv.new("uv")
    for item in objs:
        o, only = item if isinstance(item, tuple) else (item, None)
        bm, mats = world_mesh(o)
        if only is not None:
            bm.faces.ensure_lookup_table()
            gone = [f for f in bm.faces if f.index not in only]
            bmesh.ops.delete(bm, geom=gone, context="FACES")
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

def write_solid_png(path, rgb, size=8):
    """An 8-bit RGB PNG of one colour (display values 0..1)."""
    import struct, zlib
    px = bytes(max(0, min(255, round(c * 255))) for c in rgb)
    rows = b"".join(b"\x00" + px * size for _ in range(size))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))

def write_rgb_png(path, rgb):
    """An 8-bit RGB PNG from a rows x cols x 3 uint8 array, top row first."""
    import struct, zlib
    h, w, _ = rgb.shape
    rows = b"".join(b"\x00" + rgb[y].tobytes() for y in range(h))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b""))

def write_border_png(path, colour=(0.95, 0.95, 0.95), w=128, h=40, border=3):
    """A plate of one colour with a black border, 8-bit RGB."""
    import struct, zlib
    rows = bytearray()
    for yy in range(h):
        rows += b"\x00"
        for xx in range(w):
            edge = xx < border or yy < border or xx >= w - border or yy >= h - border
            rows += b"\x10\x10\x10" if edge else bytes(max(0, min(255, round(c * 255))) for c in colour)
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(bytes(rows))) + chunk(b"IEND", b""))

def export_image(image, backing=None, suffix="", alpha_only=False):
    """Save a material's image as PNG (once) and return its file name.
    backing: an RGB the transparent texels are laid over (the package
    builder would bake them over near-black: lamp lenses look through to a
    reflector); alpha_only drops the alpha without a colour."""
    fname = os.path.splitext(re.sub(r"[^A-Za-z0-9_.-]", "_", image.name))[0] + suffix + ".png"
    path = os.path.join(out_dir, "textures", fname)
    if os.path.exists(path):
        return fname
    img = image.copy()
    limit = recipe.get("texture_limit", 2048)
    w, h = img.size
    if max(w, h) > limit:
        s = limit / max(w, h)
        img.scale(max(1, int(w * s)), max(1, int(h * s)))
    if backing is not None:
        import numpy as np
        px = np.array(img.pixels[:], dtype=np.float32).reshape(-1, 4)
        if not alpha_only:
            lin = np.array([c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in backing])
            px[:, :3] = px[:, :3] * px[:, 3:4] + lin * (1 - px[:, 3:4])
        px[:, 3] = 1.0
        img.pixels[:] = px.ravel()
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)
    return fname

def material_id(mat):
    if mat in mat_index:
        return mat_index[mat]
    name = mat.name if mat else "untextured"
    if mat is not None and "mm3_texture" in mat:     # made by the exporter itself
        mat_index[mat] = len(materials)
        materials.append({"name": name, "texture": mat["mm3_texture"], "diffuse": [1.0, 1.0, 1.0, 1.0],
                          "shininess": mat.get("mm3_shininess", 0.1), "mode": int(mat.get("mm3_mode", 2))})
        return mat_index[mat]
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
        opaque = recipe.get("opaque_textures", [])
        backing = next((c for p, c in opaque.items() if re.search(p, name, re.I)), None) \
            if isinstance(opaque, dict) else ((0, 0, 0) if matches(name, opaque) else None)
        fname = export_image(image, backing, alpha_only=not isinstance(opaque, dict))
        record["texture"] = "textures/" + fname
        record["diffuse"] = [1.0, 1.0, 1.0, record["diffuse"][3]]
    for pattern, colour in recipe.get("colors", {}).items():
        if re.search(pattern, name, re.I):   # display-value RGB(A) override
            record["texture"] = None
            record["diffuse"] = list(colour) + record["diffuse"][len(colour):]
    if not record["texture"] and matches(name, recipe.get("solid_textures", [])):
        # Some donor parts (the Viper's wheels) draw untextured materials as
        # translucent; give those a small texture of their colour instead.
        fname = "solid_" + re.sub(r"[^A-Za-z0-9_.-]", "_", name) + ".png"
        write_solid_png(os.path.join(out_dir, "textures", fname), record["diffuse"][:3])
        record["texture"] = "textures/" + fname
        record["diffuse"] = [1.0, 1.0, 1.0, record["diffuse"][3]]
    mat_index[mat] = len(materials)
    materials.append(record)
    return mat_index[mat]

def rear_material_id(mat, height):
    """The material for a face behind the rear axle line: a recoloured copy
    when the recipe's "rear_colors" names it, else the material itself.
    A rule is {"tint": [r, g, b]} (multiplies), {"color": [r, g, b, a]}
    (replaces, dropping the texture) or {"backing": [r, g, b]} (the texture
    with its transparent texels over that colour), optionally only "below" a height:
    red tail lamps whose lenses share a material with the windows."""
    base_id = material_id(mat)
    name = mat.name if mat else "untextured"
    for pattern, rule in recipe.get("rear_colors", {}).items():
        if not re.search(pattern, name, re.I) or height >= rule.get("below", 1e9):
            continue
        key = ("rear", mat)
        if key not in mat_index:
            record = dict(materials[base_id], name=name + " (rear)")
            if "color" in rule:
                record["texture"] = None
                record["diffuse"] = list(rule["color"]) + record["diffuse"][len(rule["color"]):]
            elif "backing" in rule:          # the texture over another colour
                image = base_color_image(mat)
                if image:
                    record["texture"] = "textures/" + export_image(image, rule["backing"], "_rear")
            else:
                record["diffuse"] = [d * t for d, t in zip(record["diffuse"][:3], rule["tint"])] + record["diffuse"][3:]
            mat_index[key] = len(materials)
            materials.append(record)
        return mat_index[key]
    return base_id

def mesh_record(name, bm, mats, pivot):
    uv = bm.loops.layers.uv.active
    positions, normals, uvs, triangles, key = [], [], [], [], {}
    for f in bm.faces:
        mat = mats[f.material_index] if f.material_index < len(mats) else None
        centre = f.calc_center_median()
        mid = rear_material_id(mat, centre.y) if centre.z > rear_line else material_id(mat)
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
def pieces(bm):
    """Connected groups of faces (an object can hold wheels of both sides)."""
    seen, groups = set(), []
    for f in bm.faces:
        if f.index in seen:
            continue
        group, todo = [], [f]
        seen.add(f.index)
        while todo:
            g = todo.pop()
            group.append(g)
            for v in g.verts:
                for h in v.link_faces:
                    if h.index not in seen:
                        seen.add(h.index)
                        todo.append(h)
        groups.append(group)
    return groups

corners = {}
for o in parts["wheel"]:
    bm, _ = world_mesh(o)
    bm.faces.ensure_lookup_table()
    split = {}
    for group in pieces(bm):
        c = sum((f.calc_center_median() for f in group), Vector()) / len(group)
        split.setdefault((c.x > 0, c.z > 0), set()).update(f.index for f in group)
    bm.free()
    for corner, faces in split.items():
        corners.setdefault(corner, []).append((o, faces))
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

def mirror_wheel(bm):
    """Add the wheel mirrored about its own centre plane (x = centre).

    The donors share one wheel mesh per axle and turn it round for the left
    side, so the game can show either face of a wheel. Game-ready wheels
    often have no inner tyre wall or rim face; mirrored, both faces exist."""
    c, _, _ = bm_center(bm)
    uv = bm.loops.layers.uv.active
    faces = list(bm.faces)
    vmap = {}
    for f in faces:
        for v in f.verts:
            if v not in vmap:
                vmap[v] = bm.verts.new((2 * c.x - v.co.x, v.co.y, v.co.z))
    for f in faces:
        try:
            nf = bm.faces.new([vmap[v] for v in reversed(f.verts)])
        except ValueError:
            continue
        nf.material_index, nf.smooth = f.material_index, f.smooth
        if uv:
            for la, lb in zip(reversed(f.loops), nf.loops):
                lb[uv].uv = la[uv].uv
    bm.normal_update()

for corner, objs in corners.items():
    bm, mats = merge(objs)
    bm = decimate(bm, recipe.get("wheel_tris", 6000))
    print("WHEEL", names[corner], "straightened by %.1f degrees" % straighten(bm, mats))
    if recipe.get("symmetric_wheels", True):
        mirror_wheel(bm)
    c, lo, hi = bm_center(bm)
    ground = lo.y if ground is None else min(ground, lo.y)
    built[corner] = (bm, mats, c)

# Lift so the tyres stand on y = 0 and centre the wheelbase on z = 0.
front_z = sum(built[k][2].z for k in built if not k[1]) / 2
rear_z = sum(built[k][2].z for k in built if k[1]) / 2
mid_x = sum(built[k][2].x for k in built) / 4
shift = Vector((-mid_x, -ground, -(front_z + rear_z) / 2))
rear_line = rear_z + shift.z    # the rear axle, in shifted coordinates

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

def drop_faces_near(bm, mats, rules):
    """[material regex, object regex, margin]: remove faces of that material
    lying inside any connected piece of those objects (lens covers over lamp
    clusters, when the covers share a material with the windows)."""
    for mat_p, obj_p, margin in rules:
        boxes = []
        for o in parts["body"]:
            if not re.search(obj_p, object_label(o), re.I):
                continue
            ref, _ = world_mesh(o)
            bmesh.ops.translate(ref, verts=ref.verts, vec=shift)
            for group in pieces(ref):
                vs = [v.co for f in group for v in f.verts]
                boxes.append((Vector([min(v[i] for v in vs) - margin for i in range(3)]),
                              Vector([max(v[i] for v in vs) + margin for i in range(3)])))
            ref.free()
        ids = {i for i, m in enumerate(mats) if m and re.search(mat_p, m.name, re.I)}
        gone = [f for f in bm.faces if f.material_index in ids and any(
            all(lo[i] <= c[i] <= hi[i] for i in range(3))
            for c in [f.calc_center_median()] for lo, hi in boxes)]
        print("DROP", len(gone), "faces of", mat_p, "near", obj_p, "in", len(boxes), "pieces")
        bmesh.ops.delete(bm, geom=gone, context="FACES")

drop_faces_near(body, body_mats, recipe.get("drop_faces_near", []))
body = decimate(body, recipe.get("body_tris", 30000))
body.normal_update()

def bake_ao(bm, mats, patterns, size=1024, strength=0.7, samples=48):
    """Bake ambient occlusion into the faces of the named untextured
    materials (the paint): a new UV layout for them, Cycles' AO with the
    rest of the body in the scene to cast it, and one texture of the
    material's colour times the shading. Returns the number of faces."""
    import numpy as np
    ids = {i for i, m in enumerate(mats) if m and matches(m.name, patterns)}
    targets = [f for f in bm.faces if f.material_index in ids]
    if not targets:
        return 0
    def object_from(faces, name):
        me = bpy.data.meshes.new(name)
        out = bmesh.new()
        src = out.faces.layers.int.new("src")
        vmap = {}
        for number, f in enumerate(faces):
            for v in f.verts:
                if v not in vmap:
                    vmap[v] = out.verts.new(v.co)
            try:
                nf = out.faces.new([vmap[v] for v in f.verts])
                nf.smooth = f.smooth
                nf[src] = number
            except ValueError:
                pass
        # glTF splits vertices at every shading seam; welded, the paint is a
        # few large panels for the UV layout instead of loose triangles.
        bmesh.ops.remove_doubles(out, verts=out.verts, dist=1e-4)
        out.to_mesh(me)
        out.free()
        ob = bpy.data.objects.new(name, me)
        scene.collection.objects.link(ob)
        return ob
    # Surfaces hugging the paint (liners, decals, a headliner just under the
    # roof) would shadow it completely; only things standing off it cast.
    import mathutils
    near = mathutils.kdtree.KDTree(len(targets))
    for i, f in enumerate(targets):
        near.insert(f.calc_center_median(), i)
    near.balance()
    casters = [f for f in bm.faces if f.material_index not in ids
               and near.find(f.calc_center_median())[2] > recipe.get("ao_ignore_within", 0.02)]
    occluder = object_from(casters, "ao_occluder")
    paint = object_from(targets, "ao_paint")
    # The imported car is still in the scene in Blender's own orientation,
    # crossing these copies in game orientation: only the copies take part.
    hidden = [o for o in scene.objects if o not in (paint, occluder) and not o.hide_render]
    for o in hidden:
        o.hide_render = True
    for o in scene.objects:
        o.select_set(False)
    bpy.context.view_layer.objects.active = paint
    paint.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=0.004)
    bpy.ops.object.mode_set(mode="OBJECT")
    image = bpy.data.images.new("ao_bake", size, size, float_buffer=True)
    mat = bpy.data.materials.new("ao_target")
    mat.use_nodes = True
    node = mat.node_tree.nodes.new("ShaderNodeTexImage")
    node.image = image
    mat.node_tree.nodes.active = node
    paint.data.materials.append(mat)
    scene.render.engine = "CYCLES"
    scene.cycles.samples = samples
    scene.cycles.device = "CPU"
    scene.render.bake.margin = 6
    bpy.ops.object.bake(type="AO")
    for o in hidden:
        o.hide_render = False
    ao = np.array(image.pixels[:], dtype=np.float32).reshape(size, size, 4)[..., 0]
    # One baked texture per material: its colour times the shading.
    first = {}
    for i in sorted(ids):
        colour = materials[material_id(mats[i])]["diffuse"][:3]
        shade = (1 - strength) + strength * ao
        rgb = np.clip(shade[..., None] * np.asarray(colour)[None, None, :], 0, 1)
        fname = "baked_" + re.sub(r"[^A-Za-z0-9_.-]", "_", mats[i].name) + ".png"
        write_rgb_png(os.path.join(out_dir, "textures", fname), np.uint8(np.rint(rgb[::-1] * 255)))
        baked = bpy.data.materials.new(mats[i].name + " (baked)")
        baked["mm3_texture"] = "textures/" + fname
        baked["mm3_mode"] = 0          # paint: drawn with the body, as retail textured paint
        baked["mm3_shininess"] = materials[material_id(mats[i])].get("shininess", 0.25)
        mats.append(baked)
        first[i] = len(mats) - 1
    # Back into the body: the new UVs and the baked material.
    # Welding dropped collapsed faces, so pair faces by their recorded
    # index and corners by position.
    me = paint.data
    layer = me.uv_layers.active.data
    number = me.attributes["src"].data
    uv = bm.loops.layers.uv.active
    corners_of, done = [], set()
    for poly in me.polygons:
        corners = [(me.vertices[me.loops[li].vertex_index].co.copy(), layer[li].uv.copy())
                   for li in poly.loop_indices]
        corners_of.append(corners)
        n = number[poly.index].value
        done.add(n)
        for loop in targets[n].loops:
            loop[uv].uv = min(corners, key=lambda c: (c[0] - loop.vert.co).length_squared)[1]
    # Faces with no copy (a duplicate triangle, or collapsed by the weld)
    # take the layout of the nearest copied face.
    import mathutils
    tree = mathutils.kdtree.KDTree(len(corners_of))
    for i, corners in enumerate(corners_of):
        tree.insert(sum((c[0] for c in corners), Vector()) / len(corners), i)
    tree.balance()
    for n, f in enumerate(targets):
        if n in done:
            continue
        corners = corners_of[tree.find(f.calc_center_median())[1]]
        for loop in f.loops:
            loop[uv].uv = min(corners, key=lambda c: (c[0] - loop.vert.co).length_squared)[1]
    for f in targets:
        f.material_index = first[f.material_index]
    for o in (paint, occluder):
        bpy.data.objects.remove(o)
    return len(targets)

if recipe.get("bake_ao"):
    print("BAKED", bake_ao(body, body_mats, recipe["bake_ao"], recipe.get("bake_size", 1024),
                           recipe.get("ao_strength", 0.7)), "faces")

def plate_backing(bm, mats, centre, size=(0.40, 0.118)):
    """A panel just in front of the body behind the rear plate, a little
    larger than the donor's 0.387 x 0.105 m plate: its rim shows round the
    plate as a border (the plate's own background is one flat colour)."""
    path = os.path.join(out_dir, "textures", "plate_backing.png")
    write_border_png(path, recipe.get("plate_backing_color", (0.05, 0.05, 0.05)))
    mat = bpy.data.materials.new("plate backing")
    mat["mm3_texture"] = "textures/plate_backing.png"
    mats.append(mat)
    uv = bm.loops.layers.uv.active or bm.loops.layers.uv.new("uv")
    x, y, z = centre
    w, h = size[0] / 2, size[1] / 2
    vs = [bm.verts.new((x + dx, y + dy, z - 0.004)) for dx, dy in ((-w, -h), (w, -h), (w, h), (-w, h))]
    for tri, uvs in (((0, 1, 2), ((0, 1), (1, 1), (1, 0))), ((0, 2, 3), ((0, 1), (1, 0), (0, 0)))):
        f = bm.faces.new([vs[i] for i in tri])
        f.material_index = len(mats) - 1
        for loop, t in zip(f.loops, uvs):
            loop[uv].uv = (t[0], 1 - t[1])    # mesh_record flips v again
    bm.normal_update()

if "rear_plate" in recipe and recipe.get("plate_backing", False):
    plate_backing(body, body_mats, recipe["rear_plate"], tuple(recipe.get("plate_backing_size", (0.40, 0.118))))
def split_glass(bm, mats, patterns):
    """Move window faces (the recipe's "glass" materials) into their own
    bmesh for the donor's see-through glass part; faces recoloured as rear
    lamp lenses stay with the body."""
    ids = {i for i, m in enumerate(mats) if m and matches(m.name, patterns)}
    def lens(f):
        c = f.calc_center_median()
        m = mats[f.material_index]
        return c.z > rear_line and any(re.search(p, m.name, re.I) and c.y < rule.get("below", 1e9)
                                       for p, rule in recipe.get("rear_colors", {}).items())
    faces = [f for f in bm.faces if f.material_index in ids and not lens(f)]
    out = bmesh.new()
    uv_out = out.loops.layers.uv.new("uv")
    uv_in = bm.loops.layers.uv.active
    vmap = {}
    for f in faces:
        for v in f.verts:
            if v not in vmap:
                vmap[v] = out.verts.new(v.co)
        try:
            nf = out.faces.new([vmap[v] for v in f.verts])
        except ValueError:
            continue
        nf.material_index, nf.smooth = f.material_index, f.smooth
        for a, b in zip(f.loops, nf.loops):
            b[uv_out].uv = a[uv_in].uv
    bmesh.ops.delete(bm, geom=faces, context="FACES")
    out.normal_update()
    return out

if recipe.get("glass"):
    glass = split_glass(body, body_mats, recipe["glass"])
    print("GLASS", len(glass.faces), "faces")
    if glass.faces:
        meshes.append(mesh_record("GLASS_H", glass, body_mats, Vector((0, 0, 0))))
    glass.free()
meshes.insert(0, mesh_record("BODY_H", body, body_mats, Vector((0, 0, 0))))
body.free()

def lamps(patterns, rear, where):
    """Faces of the lamp parts at one end; "where" ({"material": regex,
    "below": height, "above": height}) narrows them to the lamp lenses."""
    objs = [o for o in parts["body"] if matches(object_label(o), patterns)]
    if not objs:
        return None
    bm, mats = merge(objs)
    shifted(bm)
    def wanted(f):
        c = f.calc_center_median()
        m = mats[f.material_index] if f.material_index < len(mats) else None
        return ((c.z > 0) == rear and c.y < where.get("below", 1e9) and c.y > where.get("above", -1e9)
                and (not where.get("material") or (m and re.search(where["material"], m.name, re.I))))
    keep = [f for f in bm.faces if wanted(f)]
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if f not in keep], context="FACES")
    if not bm.faces:
        bm.free()
        return None
    return bm, mats

for name, patterns, rear, where in (("HLIGHT_H", head_p, False, recipe.get("headlight_where", {})),
                                   ("TLIGHT_H", tail_p, True, recipe.get("taillight_where", {}))):
    got = lamps(patterns, rear, where)
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
if "rear_plate" in recipe:          # where the game's rear number plate goes
    model["plates"] = {"back": recipe["rear_plate"]}
    if "plate_color" in recipe:     # tint of the game's plate material
        model["plates"]["color"] = recipe["plate_color"]
with open(os.path.join(out_dir, "model.json"), "w") as f:
    json.dump(model, f, separators=(",", ":"))
for m in meshes:
    t = m["transform"]
    print("MESH", m["name"], len(m["triangles"]), "pivot",
          [round(t[i][3], 3) for i in range(3)])
print("MATERIALS", len(materials), [m["name"] for m in materials])
