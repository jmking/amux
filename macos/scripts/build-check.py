#!/usr/bin/env python3
"""Compile with swiftc directly when SwiftPM atomic writes are sandbox-blocked."""
import fcntl, json, os, platform, subprocess
from pathlib import Path
root = Path(__file__).resolve().parents[2]
os.chdir(root)
build = root / "macos/.build/chrome-check"
build.mkdir(parents=True, exist_ok=True)
os.environ["TMPDIR"] = str(build) + "/"
dep = root / "macos/.build/checkouts/SwiftTerm"
if not dep.exists():
    subprocess.run(["swift", "package", "--package-path", "macos", "resolve"], check=True)
pin = next(p["state"] for p in json.loads((root / "macos/Package.resolved").read_text())["pins"] if p["identity"] == "swiftterm")
info = build / "SwiftTermBuildInfo.swift"
info.write_text('public enum SwiftTermBuildInfo { public static let branch: String? = nil; public static let tag: String? = "' + pin["version"] + '"; public static let version: String = "' + pin["version"] + '" }')
flags = ["xcrun", "swiftc", "-disable-sandbox", "-swift-version", "5", "-target", platform.machine() + "-apple-macosx15.0", "-module-cache-path", str(build / "modules")]
library = build / "libSwiftTerm.a"
with (build / "dependency.lock").open("w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    if not library.exists():
        subprocess.run(flags + ["-emit-library", "-static", "-emit-module", "-module-name", "SwiftTerm", "-emit-module-path", str(build / "SwiftTerm.swiftmodule"), "-o", str(library)] + [str(p) for p in (dep / "Sources/SwiftTerm").rglob("*.swift")] + [str(info)], check=True)
if __name__ == "__main__":
    subprocess.run(flags + ["-I", str(build), "-L", str(build), "-lSwiftTerm", "-o", str(build / "amux")] + [str(p) for p in (root / "macos/Sources/amux").rglob("*.swift")], check=True)
    print("Full app compile and link passed")
