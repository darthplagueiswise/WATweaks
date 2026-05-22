# FLEXing module for WATweaks

This is the WATweaks adaptation of the RyukGram/FLEXing pattern.

The build script clones `FLEXTool/FLEX` into `modules/FLEXing/libflex/FLEX` when the `Classes/`
folder is missing, then the main WATweaks target compiles FLEX directly into `WATweaks.dylib`.

This avoids the previous half-dynamic state where the UI tried to call FLEX but no FLEX classes
were linked into the package.

Build note: FLEX is third-party code, so its embedded build path adds `-w -Wno-error` in the FLEX block. This mirrors the RyukGram/libFLEX behavior, where the standalone libflex target is built with `-w`.
