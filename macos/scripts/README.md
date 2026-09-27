# Chrome verification

- python3 macos/scripts/check-palette.py checks every chrome text token against every opaque surface (4.5:1), accent text, and focus indicators (3:1).
- python3 macos/scripts/build-check.py compiles and links the complete app with the pinned SwiftTerm source. This direct compiler path avoids SwiftPM atomic-write and nested sandbox failures in the task environment. It supplies the pinned dependency version for SwiftTerm's diagnostic build metadata. It does not change dependency sources or terminal rendering.
- python3 macos/scripts/visual-proof.py screenshots writes native dark/light component captures from the task base and current sources to BUILD_MATE_BEFORE_PATH and BUILD_MATE_AFTER_PATH.
- python3 macos/scripts/visual-proof.py record writes a 12-second H.264 MP4 to BUILD_MATE_RECORDING_PATH, showing tab/sidebar/empty chrome, command palette, and the new-space sheet in both modes.

Proof uses actual SwiftUI components with deterministic fixture data; it does not start terminals, load saved workspaces, or test navigation gestures. Native controls use separate Aqua and Dark Aqua hosting surfaces. The recording is a component showcase of three held captures, not a live interaction recording. PNG frames stream in memory; final artifacts use only the supplied app-owned paths. Build intermediates stay in the ignored .build directory.

Agent semantic color definitions and terminal theme definitions are unchanged. State dots follow the effective view appearance, so light and dark hosted views use the matching existing semantic shades.
