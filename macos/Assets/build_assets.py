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
    # -- room shell (Kenney Building Kit, one colormap: flatten to our palette) --
    "floor_tile": ("kenney-building-kit/Models/GLB format/floor.glb", ["--join", "--recenter", "--color", "colormap=" + CONCRETE]),
    "wall": ("kenney-building-kit/Models/GLB format/wall.glb", ["--join", "--recenter", "--color", "colormap=" + BRICK]),
    "wall_plaster": ("kenney-building-kit/Models/GLB format/wall.glb", ["--join", "--recenter", "--color", "colormap=" + PLASTER]),
    "wall_doorway": ("kenney-building-kit/Models/GLB format/wall-doorway-square.glb", ["--join", "--recenter", "--color", "colormap=" + BRICK]),
    "wall_window": ("kenney-building-kit/Models/GLB format/wall-window-square.glb", ["--drop", "ignore", "--join", "--recenter", "--color", "colormap=" + PLASTER]),
    "door": ("kenney-building-kit/Models/GLB format/door-rotate-square-a.glb", ["--color", "colormap=0.28,0.20,0.14"]),
    "column": ("kenney-building-kit/Models/GLB format/column.glb", ["--join", "--recenter", "--color", "colormap=" + CONCRETE]),
    "pipe_detail": ("kenney-building-kit/Models/GLB format/detail-pipe.glb", ["--join", "--recenter", "--color", "colormap=0.12,0.12,0.13"]),

    # -- workstations --
    "desk": ("poly-pizza-workstations/desk_quaternius_*.glb", ["--join", "--scale", "0.85", "--recenter"]),
    "chair": ("poly-pizza-workstations/office_chair_quaternius_*.glb", ["--join", "--recenter"]),
    "monitor": ("kenney-furniture-kit/Models/GLTF format/computerScreen.glb", ["--join", "--scale", "1.6", "--recenter"]),
    "keyboard": ("kenney-furniture-kit/Models/GLTF format/computerKeyboard.glb", ["--join", "--scale", "1.6", "--recenter"]),
    "mouse": ("kenney-furniture-kit/Models/GLTF format/computerMouse.glb", ["--join", "--scale", "1.6", "--recenter"]),
    "server_rack": ("quaternius-cyberpunk-game-kit/Computer Large.glb",
                    ["--join", "--recenter", "--color", "Orange=" + DARK, "--emissive", "Screen=" + SCREEN_GREEN + ",3"]),
    "server_tower": ("poly-pizza-workstations/scifi_computer_quaternius_*.glb", ["--join", "--recenter"]),
    "cable": ("quaternius-cyberpunk-game-kit/Cable Long.glb", []),
    "cable_short": ("quaternius-cyberpunk-game-kit/Cable.glb", []),
    "cables_droop": ("kenney-retro-urban-kit/Models/GLB format/detail-cables-type-a.glb", ["--join", "--recenter", "--color", "colormap=0.06,0.06,0.07"]),

    # -- the corner the crew lives in --
    "couch": ("poly-pizza-workstations/damaged_couch_quaternius_*.glb", ["--join", "--scale", "0.85", "--recenter"]),
    "pallet": ("polypizza-hacker-props/pallet_quaternius_*.glb", ["--join", "--recenter"]),
    "pillow": ("kenney-furniture-kit/Models/GLTF format/pillow.glb", ["--join", "--scale", "1.6", "--recenter"]),
    "shelf": ("poly-pizza-workstations/shelf_tall_quaternius_*.glb", ["--join", "--scale", "0.65", "--recenter"]),
    "arcade": ("kenney-mini-arcade/Models/GLB format/arcade-machine.glb", ["--join", "--scale", "2.4", "--recenter"]),
    "crt": ("quaternius-cyberpunk-game-kit/TV.glb", ["--join", "--scale", "0.45", "--recenter", "--emissive", "Texture_Signs=" + SCREEN_GREEN + ",2"]),
    "neon_sign": ("quaternius-cyberpunk-game-kit/Cyberpunk Signs.glb",
                  ["--join", "--keep", "Sign_1", "--recenter", "--emissive", "Texture_Signs=1.0,0.25,0.55,4"]),
    "pendant": ("polypizza-hacker-props/light-ceiling-single_quaternius_*.glb", ["--join"]),
    "boxes": ("poly-pizza-workstations/cardboard_boxes_quaternius_*.glb", ["--join", "--recenter"]),
    "crate": ("polypizza-hacker-props/crate_quaternius_*.glb", ["--join", "--scale", "0.5", "--recenter"]),
    "trash_bags": ("polypizza-hacker-props/trash-bags_quaternius_*.glb", ["--join", "--recenter"]),
    "papers": ("polypizza-hacker-props/debris-papers_quaternius_*.glb", ["--join", "--recenter"]),
    "headphones": ("polypizza-hacker-props/headphones_*.glb", ["--join", "--recenter"]),
    "coat_rack": ("polypizza-hacker-props/coat-rack-standing_*.glb", ["--join", "--recenter"]),
    "jacket": ("polypizza-hacker-props/jacket_*.glb", ["--join", "--recenter"]),
    "skateboard": ("polypizza-hacker-props/skateboard_*.glb", ["--join", "--recenter"]),
    "coffee_machine": ("polypizza-hacker-props/kitchen-coffee-machine_kenney_*.glb", ["--join", "--recenter"]),
    "kitchen_cabinet": ("kenney-furniture-kit/Models/GLTF format/kitchenCabinet.glb", ["--join", "--recenter"]),
    "fridge": ("polypizza-hacker-props/can-fridge_*.glb", ["--join", "--scale", "0.42", "--recenter"]),
    "router": ("polypizza-hacker-props/wireless-machine_*.glb", ["--join", "--recenter"]),

    # -- food --
    "pizza_box": ("kenney-food-kit/Models/GLB format/pizza-box.glb", ["--join", "--scale", "0.45", "--recenter"]),
    "pizza_slice": ("kenney-food-kit/Models/GLB format/pizza.glb", ["--keep", "slice1", "--join", "--scale", "0.45", "--recenter"]),
    "pizza": ("kenney-food-kit/Models/GLB format/pizza.glb", ["--join", "--scale", "0.45", "--recenter"]),
    "can": ("kenney-food-kit/Models/GLB format/soda-can.glb", ["--join", "--scale", "0.35", "--recenter"]),
    "can_crushed": ("kenney-food-kit/Models/GLB format/soda-can-crushed.glb", ["--join", "--scale", "0.35", "--recenter"]),
    "mug": ("kenney-food-kit/Models/GLB format/mug.glb", ["--join", "--scale", "0.3", "--recenter"]),
    "cup": ("kenney-food-kit/Models/GLB format/cup-coffee.glb", ["--join", "--scale", "0.35", "--recenter"]),
    "styrofoam": ("kenney-food-kit/Models/GLB format/styrofoam.glb", ["--join", "--scale", "0.45", "--recenter"]),


    # -- the yard (scouted for a warehouse exterior; see Assets/work/yard-design.json) --
    "container": ("kenney-retro-urban-kit/Models/GLB format/truck-grey-cargo.glb", ["--join", "--recenter", "--scale", "3.5", "--color", "truck=0.30,0.36,0.42"]),
    "container_tagged": ("kenney-retro-urban-kit/Models/GLB format/truck-green-cargo.glb", ["--join", "--recenter", "--scale", "3.5", "--color", "truck_alien=0.46,0.24,0.18"]),
    "truck_box": ("kenney-retro-urban-kit/Models/GLB format/truck-grey.glb", ["--join", "--recenter", "--scale", "3", "--color", "truck=0.62,0.60,0.56"]),
    "dumpster": ("polypizza-hacker-props/dumpster_quaternius_*.glb", ["--join", "--recenter", "--scale", "0.72"]),
    "skip_open": ("polypizza-hacker-props/trash-container-open_quaternius_*.glb", ["--join", "--recenter", "--scale", "0.5"]),
    "dumpster_open": ("kenney-retro-urban-kit/Models/GLB format/detail-dumpster-open.glb", ["--join", "--recenter", "--scale", "2.7", "--color", "dirt=0.12,0.10,0.08", "--color", "roof=0.20,0.26,0.22", "--color", "wall=0.22,0.30,0.24", "--color", "wall_metal=0.20,0.22,0.24"]),
    "drum": ("polypizza-hacker-props/barrel_quaternius_*.glb", ["--join", "--recenter", "--scale", "0.8"]),
    "propane_tank": ("polypizza-hacker-props/propane-tank_quaternius_*.glb", ["--join", "--recenter", "--scale", "0.5"]),
    "pallet_yard": ("kenney-retro-urban-kit/Models/GLB format/pallet.glb", ["--join", "--recenter", "--scale", "1.2", "--color", "planks=0.48,0.36,0.22"]),
    "pallet_broken": ("polypizza-hacker-props/pallet-broken_quaternius_*.glb", ["--join", "--recenter", "--scale", "0.7"]),
    "scaffold": ("kenney-retro-urban-kit/Models/GLB format/scaffolding-structure.glb", ["--join", "--recenter", "--scale", "2", "--color", "bars=0.36,0.34,0.32", "--color", "metal=0.40,0.38,0.36"]),
    "facade_wall": ("kenney-retro-urban-kit/Models/GLB format/wall-a-flat.glb", ["--join", "--recenter", "--scale", "3", "--color", "wall_lines=0.40,0.25,0.20"]),
    "facade_painted": ("kenney-retro-urban-kit/Models/GLB format/wall-a-flat-painted.glb", ["--join", "--recenter", "--scale", "3", "--color", "wall=0.33,0.36,0.38"]),
    "facade_garage": ("kenney-retro-urban-kit/Models/GLB format/wall-a-flat-garage.glb", ["--join", "--recenter", "--scale", "3", "--color", "concrete=0.36,0.36,0.35", "--color", "wall=0.40,0.25,0.20", "--color", "wall_garage=0.28,0.30,0.32"]),
    "facade_garage_metal": ("kenney-retro-urban-kit/Models/GLB format/wall-b-flat-garage.glb", ["--join", "--recenter", "--scale", "3", "--color", "wall_garage=0.26,0.28,0.30", "--color", "wall_metal=0.30,0.32,0.34"]),
    "facade_window": ("kenney-retro-urban-kit/Models/GLB format/wall-a-flat-window.glb", ["--join", "--recenter", "--scale", "3", "--color", "metal=0.18,0.18,0.19", "--color", "wall_lines=0.40,0.25,0.20", "--color", "windows=0.22,0.28,0.34"]),
    "facade_metal": ("kenney-retro-urban-kit/Models/GLB format/wall-b-flat.glb", ["--join", "--recenter", "--scale", "3", "--color", "wall_metal=0.34,0.36,0.38"]),
    "roof_metal": ("kenney-retro-urban-kit/Models/GLB format/roof-metal-type-a.glb", ["--join", "--recenter", "--scale", "3", "--color", "concrete=0.30,0.30,0.30", "--color", "roof_plates=0.26,0.28,0.30"]),
    "barrier_concrete": ("kenney-retro-urban-kit/Models/GLB format/detail-barrier-strong-type-a.glb", ["--join", "--recenter", "--scale", "3", "--color", "concrete=0.50,0.50,0.48"]),
    "barrier_striped": ("kenney-retro-urban-kit/Models/GLB format/detail-barrier-type-a.glb", ["--join", "--recenter", "--scale", "3", "--color", "metal=0.35,0.35,0.35", "--color", "signs=0.78,0.66,0.30"]),
    "cone": ("kenney-city-kit-roads/Models/GLB format/construction-cone.glb", ["--join", "--recenter", "--scale", "8"]),
    "fence_rail": ("kenney-retro-urban-kit/Models/GLB format/wall-fence.glb", ["--join", "--recenter", "--scale", "3", "--color", "bars=0.25,0.25,0.26", "--color", "concrete=0.40,0.40,0.39", "--color", "wall_lines=0.40,0.25,0.20"]),
    "elec_pole": ("kenney-city-kit-roads/Models/GLB format/electricity-pole.glb", ["--join", "--recenter", "--scale", "10", "--color", "colormap=0.30,0.24,0.18"]),
    "elec_wires": ("kenney-city-kit-roads/Models/GLB format/electricity-wires.glb", ["--join", "--recenter", "--scale", "10", "--color", "colormap=0.12,0.12,0.12"]),
    "lamp_post": ("kenney-city-kit-roads/Models/GLB format/light-square.glb", ["--join", "--recenter", "--scale", "8", "--color", "colormap=0.20,0.21,0.22"]),
    "warning_light": ("kenney-city-kit-roads/Models/GLB format/construction-light.glb", ["--join", "--recenter", "--scale", "5"]),
    "ladder": ("polypizza-hacker-props/metal-ladder_*.glb", ["--join", "--recenter", "--scale", "0.1"]),
    "yard_asphalt": ("kenney-retro-urban-kit/Models/GLB format/road-asphalt-damaged.glb", ["--join", "--recenter", "--scale", "3", "--color", "asphalt=0.10,0.10,0.11", "--color", "concreteSmooth=0.14,0.14,0.145"]),
    # -- the city outside --
    "skyscraper_a": ("kenney-city-kit-commercial/Models/GLB format/building-skyscraper-a.glb", ["--join", "--scale", "10", "--recenter", "--color", "colormap=" + DARK]),
    "skyscraper_b": ("kenney-city-kit-commercial/Models/GLB format/building-skyscraper-b.glb", ["--join", "--scale", "10", "--recenter", "--color", "colormap=" + DARK]),
    "skyscraper_c": ("kenney-city-kit-commercial/Models/GLB format/building-skyscraper-c.glb", ["--join", "--scale", "10", "--recenter", "--color", "colormap=" + DARK]),
    "skyscraper_d": ("kenney-city-kit-commercial/Models/GLB format/building-skyscraper-d.glb", ["--join", "--scale", "10", "--recenter", "--color", "colormap=" + DARK]),
    "skyscraper_e": ("kenney-city-kit-commercial/Models/GLB format/building-skyscraper-e.glb", ["--join", "--scale", "10", "--recenter", "--color", "colormap=" + DARK]),
    "building_low": ("kenney-city-kit-commercial/Models/GLB format/low-detail-building-a.glb", ["--join", "--scale", "10", "--recenter", "--color", "colormap=" + DARK]),
    "building_wide": ("kenney-city-kit-commercial/Models/GLB format/low-detail-building-wide-a.glb", ["--join", "--scale", "10", "--recenter", "--color", "colormap=" + DARK]),
    "building_window": ("kenney-modular-buildings/Models/GLB format/building-window.glb", ["--join", "--scale", "3.2", "--recenter", "--color", "colormap=0.06,0.06,0.07"]),
    "tv_tower": ("quaternius-cyberpunk-game-kit/TV Tower.glb", ["--join", "--recenter"]),
    "antenna": ("quaternius-cyberpunk-game-kit/Antenna.glb", ["--join", "--recenter"]),
    "ac_unit": ("quaternius-cyberpunk-game-kit/Air Conditioner.glb", ["--join", "--recenter"]),
    "ac_stacked": ("quaternius-cyberpunk-game-kit/Ac Stacked.glb", ["--join", "--recenter"]),
    "pipe": ("quaternius-cyberpunk-game-kit/Pipe.glb", ["--join", "--recenter"]),
    "rail": ("quaternius-cyberpunk-game-kit/Rail.glb", ["--join", "--recenter"]),
    "streetlight": ("quaternius-cyberpunk-game-kit/Streetlight.glb", ["--join", "--recenter"]),
}


def run(name, pattern, options):
    matches = sorted(glob.glob(os.path.join(SRC, pattern)))
    if not matches:
        return name, None, "MISSING source: " + pattern
    src = matches[0]
    dst = os.path.join(OUT, name + ".usdz")
    # matte by default: the kits' 0.5 roughness mirrors the day sky and washes every colour out
    if "--rough" not in options:
        options = options + ["--rough", "0.85"]
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
