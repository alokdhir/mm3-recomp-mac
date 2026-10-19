# Importing cars from glTF, FBX or .blend models

`blender_source.py` turns a downloaded car model (Sketchfab glTF/GLB, FBX or a
.blend) into the neutral `model.json` that mm3-recomp's car tools build
packages from. A recipe in `recipes/` says which parts are which. The models
themselves are not in this repository; each recipe names its source and
licence.

## Steps

1. Unzip the download where the recipe's `source` points.
2. Export (Blender 4.x, headless):

       /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup \
         -P tools/car-import/blender_source.py -- tools/car-import/recipes/porsche930.json /tmp/p930

3. Menu icons, then the package (a Python with NumPy, SciPy and Pillow):

       cd third_party/mm3-recomp/tools/car-models
       python preview.py /tmp/p930/model.json --out /tmp/p930/icons --name "Porsche 930 Turbo" --icons
       python build_package.py /tmp/p930/model.json \
         "$HOME/Library/Application Support/Midtown Madness 3/CarPackages/porsche930" \
         --car-id 9009 --icons /tmp/p930/icons

4. Point the car at the package in `third_party/mm3-recomp/tools/car-mods/cars.local.json`
   (`"model_package"`; `"hidden": true` keeps a slot without a model out of
   the menus), quit the game, then
   `python prepare.py --game-dir <repo>/game_files --apply` and copy
   `game_files` into the app's `Contents/Resources/game_files`.

## Recipe fields

| Field | Meaning |
|---|---|
| `source` | the model file, relative to the recipe or `~` |
| `forward` | Blender axis the nose points along (`+Y`, `-Y`, `+X`, `-X`). Check it on the geometry (spoiler, rear glass), not on material names |
| `scale` | to real size: real wheelbase / model wheelbase |
| `drop` | regexes matched against `object name, mesh name, material names` for parts to leave out (clear coats, ground planes, interior props) |
| `wheel` | regexes for wheel parts; they are sorted into the four corners |
| `headlight`, `taillight` | regexes for lamp parts; their centres place the game's lights |
| `colors` | material regex to display-value RGB, replacing that material's colour |
| `opaque_textures` | material regexes whose texture alpha is dropped, or `{regex: rgb}` to lay transparent texels over that colour (lamp lenses over a chrome reflector) |
| `body_tris`, `wheel_tris` | triangle budgets (the game copes with ~30k and ~6k) |
| `solid_textures` | material regexes given a small texture of their colour (untextured wheel parts) |
| `drop_faces_near` | `[material, object, margin]`: drop that material's faces inside pieces of those objects (lens covers sharing the windows' material) |
| `rear_colors` | material regex to `{"tint": rgb}` or `{"color": rgba, "below": height}` for faces behind the rear axle (red tail-lamp lenses) |
| `headlight_where`, `taillight_where` | `{"material", "below", "above"}`: narrow the lamp helpers to the lenses |
| `symmetric_wheels` | default true: each wheel also gets a mirrored copy (the donors show the inside of a shared wheel mesh on the left) |
| `rear_plate` | `[x, y, z]` in the exported coordinates: the donor's rear number plate (with the player's plate text) is moved there; front plates stay hidden |
| `plate_color` | display RGB of the rear plate background: the builder gives the car a recoloured copy of the game's plate font atlas |
| `plate_backing` | true: a panel (`plate_backing_color`, default black; `plate_backing_size`, default 0.40 x 0.118 m) behind the plate, showing as a border |
| `hero_metallic` | material regexes rendered as metallic paint by `render_hero.py` |

Use a Koenigsegg-donor slot: the Viper donor draws an imported car's driver-side wheels translucent.

## Loading screen

    Blender -b --factory-startup -P tools/car-import/render_hero.py -- recipe.json /tmp/hero.png
    python tools/car-import/compose_loading.py /tmp/hero.png Default_Koenigsegg.tga Default_<alias>.tga

`Default_Koenigsegg.tga` is the retail screen from `Data_dvd.zip` `LoadingScreens/`;
add the result to the package's `package.json` as
`{"archive": "Data_dvd.zip", "path": "LoadingScreens/Default_<alias>.tga", ...}`.

Wheels modelled steered or cambered are straightened about their tyre's axle.
Patterns match child object names (`Object_132`), not the parent empties
the glTF importer prints alongside them.
