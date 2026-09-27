#!/usr/bin/env python3
"""Native view proof. Outputs only to Build Mate's evidence paths (or preview stdout).
The movie presents empty-state/tab chrome, command palette, and sheet in both modes.
This is a deterministic component showcase, not a recording of navigation gestures.
"""
import importlib.util, os, subprocess, sys
sys.dont_write_bytecode = True
from pathlib import Path
spec = importlib.util.spec_from_file_location("build_check", Path(__file__).with_name("build-check.py"))
bc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bc)
BASE = "aae89f713437bfd78967933fbd2cf39ff1075ed7"
def executable(before=False):
    folder = bc.build / (("before-" if before else "after-") + str(os.getpid()))
    folder.mkdir(exist_ok=True)
    files = []
    for path in (bc.root / "macos/Sources/amux").rglob("*.swift"):
        source = subprocess.check_output(["git", "show", BASE + ":" + str(path.relative_to(bc.root))]).decode() if before else path.read_text()
        if path.name == "AmuxApp.swift":
            source = source.replace("@main\n", "", 1)
        target = folder / path.name
        target.write_text(source)
        files.append(str(target))
    output = folder / "chrome-proof"
    subprocess.run(bc.flags + ["-I", str(bc.build), "-L", str(bc.build), "-lSwiftTerm", "-o", str(output)] + files + [str(Path(__file__).with_name("ChromeProof.swift"))], check=True)
    return output
def png(exe, phase):
    return subprocess.check_output([str(exe), str(phase)])
if sys.argv[1] == "screenshots":
    Path(os.environ["BUILD_MATE_BEFORE_PATH"]).write_bytes(png(executable(True), 0))
    Path(os.environ["BUILD_MATE_AFTER_PATH"]).write_bytes(png(executable(), 0))
elif sys.argv[1] == "record":
    exe = executable()
    # Three native view captures held for four seconds each, streamed without temp artifacts.
    frames = [png(exe, phase) for phase in range(3)]
    subprocess.run(["ffmpeg", "-y", "-f", "image2pipe", "-framerate", "1/4", "-vcodec", "png",
                    "-i", "-", "-vf", "scale=1100:1120", "-r", "30", "-c:v", "libx264",
                    "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                    os.environ["BUILD_MATE_RECORDING_PATH"]], input=b"".join(frames), check=True)
elif sys.argv[1] == "preview":
    sys.stdout.buffer.write(png(executable(), int(sys.argv[2]) if len(sys.argv) > 2 else 0))
elif sys.argv[1] == "compile":
    executable()
    executable(True)
else:
    raise SystemExit("Use screenshots, record, preview, or compile")
