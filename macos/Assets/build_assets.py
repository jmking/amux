#!/usr/bin/env python3
"""Convert the selected CC0 source models into the app's world assets.

    python3 macos/Assets/build_assets.py [name ...]

Runs convert.py under Blender once per entry in MANIFEST, several at a time, into
macos/Sources/amux/Resources/world/<name>.usdz, and writes a report with each
asset's bounding box so a wrongly scaled model is caught here rather than in
the scene. Names on the command line limit the run to those entries.

Sources are catalogued (with licence evidence) in Assets/work/catalog/*.json;
the choices below follow Assets/work/catalog/selection.json.
"""
import glob
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
BLENDER = os.path.join(REPO, "tools", "Blender.app", "Contents", "MacOS", "Blender")
CONVERT = os.path.join(HERE, "convert.py")
SRC = os.path.join(HERE, "src")
OUT = os.path.join(REPO, "macos", "Sources", "amux", "Resources", "world")
REPORT = os.path.join(HERE, "work", "report.txt")

DARK = "0.05,0.05,0.06"
CONCRETE = "0.20,0.20,0.21"
BRICK = "0.34,0.20,0.16"
PLASTER = "0.30,0.30,0.29"
SCREEN_GREEN = "0.25,1.0,0.45"

# name -> (source glob relative to Assets/src, [convert.py options])
MANIFEST = {
    # -- the crew --
    # Blender exports one clip per file, so the character is exported once as
    # the model (carrying its idle) and once more per clip; the app plays the
    # clip files onto the model, whose skeleton they share. Not recentred: the
    # rig's control bones inflate the bounding box and would shift the body off
    # its authored origin, which is already at the feet.
    "character": ("polypizza-hacker-props/hoodie-character_quaternius_*.glb",
                  ["--strip-anim-prefix", "--rename", "Purple=Hoodie", "--action", "Idle_Neutral"]),
    "character_walk": ("polypizza-hacker-props/hoodie-character_quaternius_*.glb",
                       ["--strip-anim-prefix", "--rename", "Purple=Hoodie", "--action", "Walk"]),
    "character_wave": ("polypizza-hacker-props/hoodie-character_quaternius_*.glb",
                       ["--strip-anim-prefix", "--rename", "Purple=Hoodie", "--action", "Wave"]),
    "character_hit": ("polypizza-hacker-props/hoodie-character_quaternius_*.glb",
                      ["--strip-anim-prefix", "--rename", "Purple=Hoodie", "--action", "HitRecieve"]),
    "character_idle2": ("polypizza-hacker-props/hoodie-character_quaternius_*.glb",
                        ["--strip-anim-prefix", "--rename", "Purple=Hoodie", "--action", "Idle"]),
    "character_interact": ("polypizza-hacker-props/hoodie-character_quaternius_*.glb",
                           ["--strip-anim-prefix", "--rename", "Purple=Hoodie", "--action", "Interact"]),

    # -- room shell (Kenney Building Kit, one colormap: flatten to our palette) --
    "floor_tile": ("kenney-building-kit/Models/GLB format/floor.glb", ["--recenter", "--color", "colormap=" + CONCRETE]),
    "wall": ("kenney-building-kit/Models/GLB format/wall.glb", ["--recenter", "--color", "colormap=" + BRICK]),
    "wall_plaster": ("kenney-building-kit/Models/GLB format/wall.glb", ["--recenter", "--color", "colormap=" + PLASTER]),
    "wall_doorway": ("kenney-building-kit/Models/GLB format/wall-doorway-square.glb", ["--recenter", "--color", "colormap=" + BRICK]),
    "wall_window": ("kenney-building-kit/Models/GLB format/wall-window-square.glb", ["--recenter", "--color", "colormap=" + PLASTER]),
    "door": ("kenney-building-kit/Models/GLB format/door-rotate-square-a.glb", ["--color", "colormap=0.28,0.20,0.14"]),
    "column": ("kenney-building-kit/Models/GLB format/column.glb", ["--recenter", "--color", "colormap=" + CONCRETE]),
    "pipe_detail": ("kenney-building-kit/Models/GLB format/detail-pipe.glb", ["--recenter", "--color", "colormap=0.12,0.12,0.13"]),

    # -- workstations --
    "desk": ("poly-pizza-workstations/desk_quaternius_*.glb", ["--scale", "0.85", "--recenter"]),
    "chair": ("poly-pizza-workstations/office_chair_quaternius_*.glb", ["--recenter"]),
    "monitor": ("kenney-furniture-kit/Models/GLTF format/computerScreen.glb", ["--scale", "1.6", "--recenter"]),
    "keyboard": ("kenney-furniture-kit/Models/GLTF format/computerKeyboard.glb", ["--scale", "1.6", "--recenter"]),
    "mouse": ("kenney-furniture-kit/Models/GLTF format/computerMouse.glb", ["--scale", "1.6", "--recenter"]),
    "server_rack": ("quaternius-cyberpunk-game-kit/Computer Large.glb",
                    ["--recenter", "--color", "Orange=" + DARK, "--emissive", "Screen=" + SCREEN_GREEN + ",3"]),
    "server_tower": ("poly-pizza-workstations/scifi_computer_quaternius_*.glb", ["--recenter"]),
    "cable": ("quaternius-cyberpunk-game-kit/Cable Long.glb", []),
    "cable_short": ("quaternius-cyberpunk-game-kit/Cable.glb", []),
    "cables_droop": ("kenney-retro-urban-kit/Models/GLB format/detail-cables-type-a.glb", ["--recenter", "--color", "colormap=0.06,0.06,0.07"]),

    # -- the corner the crew lives in --
    "couch": ("poly-pizza-workstations/damaged_couch_quaternius_*.glb", ["--scale", "0.85", "--recenter"]),
    "pallet": ("polypizza-hacker-props/pallet_quaternius_*.glb", ["--recenter"]),
    "pillow": ("kenney-furniture-kit/Models/GLTF format/pillow.glb", ["--scale", "1.6", "--recenter"]),
    "shelf": ("poly-pizza-workstations/shelf_tall_quaternius_*.glb", ["--scale", "0.65", "--recenter"]),
    "arcade": ("kenney-mini-arcade/Models/GLB format/arcade-machine.glb", ["--scale", "2.4", "--recenter"]),
    "crt": ("quaternius-cyberpunk-game-kit/TV.glb", ["--scale", "0.45", "--recenter", "--emissive", "Texture_Signs=" + SCREEN_GREEN + ",2"]),
    "neon_sign": ("quaternius-cyberpunk-game-kit/Cyberpunk Signs.glb",
                  ["--keep", "Sign_1", "--recenter", "--emissive", "Texture_Signs=1.0,0.25,0.55,4"]),
    "pendant": ("polypizza-hacker-props/light-ceiling-single_quaternius_*.glb", []),
    "boxes": ("poly-pizza-workstations/cardboard_boxes_quaternius_*.glb", ["--recenter"]),
    "crate": ("polypizza-hacker-props/crate_quaternius_*.glb", ["--scale", "0.5", "--recenter"]),
    "trash_bags": ("polypizza-hacker-props/trash-bags_quaternius_*.glb", ["--recenter"]),
    "papers": ("polypizza-hacker-props/debris-papers_quaternius_*.glb", ["--recenter"]),
    "headphones": ("polypizza-hacker-props/headphones_*.glb", ["--recenter"]),
    "coat_rack": ("polypizza-hacker-props/coat-rack-standing_*.glb", ["--recenter"]),
    "jacket": ("polypizza-hacker-props/jacket_*.glb", ["--recenter"]),
    "skateboard": ("polypizza-hacker-props/skateboard_*.glb", ["--recenter"]),
    "fridge": ("polypizza-hacker-props/can-fridge_*.glb", ["--scale", "0.42", "--recenter"]),
    "router": ("polypizza-hacker-props/wireless-machine_*.glb", ["--recenter"]),

    # -- food --
    "pizza_box": ("kenney-food-kit/Models/GLB format/pizza-box.glb", ["--scale", "0.45", "--recenter"]),
    "pizza": ("kenney-food-kit/Models/GLB format/pizza.glb", ["--scale", "0.45", "--recenter"]),
    "can": ("kenney-food-kit/Models/GLB format/soda-can.glb", ["--scale", "0.35", "--recenter"]),
    "can_crushed": ("kenney-food-kit/Models/GLB format/soda-can-crushed.glb", ["--scale", "0.35", "--recenter"]),
    "mug": ("kenney-food-kit/Models/GLB format/mug.glb", ["--scale", "0.3", "--recenter"]),
    "cup": ("kenney-food-kit/Models/GLB format/cup-coffee.glb", ["--scale", "0.35", "--recenter"]),
    "styrofoam": ("kenney-food-kit/Models/GLB format/styrofoam.glb", ["--scale", "0.45", "--recenter"]),

    # -- the city outside --
    "skyscraper_a": ("kenney-city-kit-commercial/Models/GLB format/building-skyscraper-a.glb", ["--scale", "10", "--recenter", "--color", "colormap=" + DARK]),
    "skyscraper_b": ("kenney-city-kit-commercial/Models/GLB format/building-skyscraper-b.glb", ["--scale", "10", "--recenter", "--color", "colormap=" + DARK]),
    "skyscraper_c": ("kenney-city-kit-commercial/Models/GLB format/building-skyscraper-c.glb", ["--scale", "10", "--recenter", "--color", "colormap=" + DARK]),
    "skyscraper_d": ("kenney-city-kit-commercial/Models/GLB format/building-skyscraper-d.glb", ["--scale", "10", "--recenter", "--color", "colormap=" + DARK]),
    "skyscraper_e": ("kenney-city-kit-commercial/Models/GLB format/building-skyscraper-e.glb", ["--scale", "10", "--recenter", "--color", "colormap=" + DARK]),
    "building_low": ("kenney-city-kit-commercial/Models/GLB format/low-detail-building-a.glb", ["--scale", "10", "--recenter", "--color", "colormap=" + DARK]),
    "building_wide": ("kenney-city-kit-commercial/Models/GLB format/low-detail-building-wide-a.glb", ["--scale", "10", "--recenter", "--color", "colormap=" + DARK]),
    "building_window": ("kenney-modular-buildings/Models/GLB format/building-window.glb", ["--scale", "3.2", "--recenter", "--color", "colormap=0.06,0.06,0.07"]),
    "tv_tower": ("quaternius-cyberpunk-game-kit/TV Tower.glb", ["--recenter"]),
    "antenna": ("quaternius-cyberpunk-game-kit/Antenna.glb", ["--recenter"]),
    "ac_unit": ("quaternius-cyberpunk-game-kit/Air Conditioner.glb", ["--recenter"]),
    "ac_stacked": ("quaternius-cyberpunk-game-kit/Ac Stacked.glb", ["--recenter"]),
    "pipe": ("quaternius-cyberpunk-game-kit/Pipe.glb", ["--recenter"]),
    "rail": ("quaternius-cyberpunk-game-kit/Rail.glb", ["--recenter"]),
    "streetlight": ("quaternius-cyberpunk-game-kit/Streetlight.glb", ["--recenter"]),
}


def run(name, pattern, options):
    matches = sorted(glob.glob(os.path.join(SRC, pattern)))
    if not matches:
        return name, None, "MISSING source: " + pattern
    src = matches[0]
    dst = os.path.join(OUT, name + ".usdz")
    cmd = [BLENDER, "-b", "--python", CONVERT, "--", src, dst] + options
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    lines = [l for l in (p.stdout + p.stderr).splitlines() if l.startswith("convert:") or "Error" in l or "Traceback" in l]
    bbox = next((l for l in lines if "bbox:" in l), "")
    warn = [l for l in lines if "WARNING" in l or "Error" in l or "Traceback" in l]
    ok = os.path.exists(dst) and p.returncode == 0
    size = os.path.getsize(dst) // 1024 if os.path.exists(dst) else 0
    summary = "%s %4d KB  %s%s" % ("ok " if ok else "FAIL", size, bbox.replace("convert: ", ""),
                                   ("  | " + "; ".join(warn)) if warn else "")
    detail = "\n".join(lines[-12:]) if not ok else ""
    return name, ok, summary + ("\n" + detail if detail else "")


def main():
    only = set(sys.argv[1:])
    entries = [(n, *v) for n, v in MANIFEST.items() if not only or n in only]
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(os.path.dirname(REPORT), exist_ok=True)
    print("converting %d assets with %s" % (len(entries), BLENDER), flush=True)
    results = []
    with ThreadPoolExecutor(max_workers=6) as ex:
        for name, ok, summary in ex.map(lambda e: run(*e), entries):
            print("%-16s %s" % (name, summary), flush=True)
            results.append((name, ok, summary))
    failed = [n for n, ok, _ in results if not ok]
    with open(REPORT, "w") as f:
        for name, ok, summary in results:
            f.write("%-16s %s\n" % (name, summary))
    print("\n%d ok, %d failed%s" % (len(results) - len(failed), len(failed), (": " + ", ".join(failed)) if failed else ""))
    print("report: " + REPORT)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
