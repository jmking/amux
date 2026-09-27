#!/usr/bin/env python3
"""Validate normal-size chrome text and focus contrast from the actual tokens."""
import re
from pathlib import Path
source = (Path(__file__).resolve().parents[1] / "Sources/amux/Theme.swift").read_text()
def luminance(value):
    rgb = [(value >> shift & 255) / 255 for shift in (16, 8, 0)]
    return sum(c * w for c, w in zip(
        [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in rgb],
        [.2126, .7152, .0722]))
def contrast(a, b):
    a, b = sorted([luminance(a), luminance(b)])
    return (b + .05) / (a + .05)
for mode in ("dark", "light"):
    block = source.split("static let " + mode + "Mode = Palette(")[1].split("\n\n")[0]
    tokens = {k: int(v, 16) for k, v in re.findall(r"(\w+): SwiftUI.Color\(hex: 0x([0-9a-f]+)\)", block)}
    ratios = []
    for text in ("ink", "dim", "faint", "faint2"):
        for surface in ("bg", "panel", "mass", "chrome", "hover"):
            ratio = contrast(tokens[text], tokens[surface])
            assert ratio >= 4.5, (mode, text, surface, ratio)
            ratios.append(ratio)
    assert contrast(tokens["spot"], tokens["spotInk"]) >= 4.5
    for surface in ("bg", "panel", "mass", "chrome", "hover"):
        assert contrast(tokens["focus"], tokens[surface]) >= 3, (mode, surface)
    assert len({tokens[k] for k in ("panel", "mass", "chrome", "hover")}) == 4
    print(f"{mode}: text minimum {min(ratios):.2f}:1; accent and focus passed")
