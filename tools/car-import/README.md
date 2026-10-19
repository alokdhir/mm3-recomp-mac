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
| `opaque_textures` | material regexes whose texture alpha is dropped (detail stored under transparent texels) |
| `body_tris`, `wheel_tris` | triangle budgets (the game copes with ~30k and ~6k) |

Wheels modelled steered or cambered are straightened about their tyre's axle.
Patterns match child object names (`Object_132`), not the parent empties
the glTF importer prints alongside them.
