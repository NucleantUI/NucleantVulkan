# Linux dependencies

Like macOS/iOS (Dependencies/macos/, vendored xcframeworks committed into
the repo), `CVulkan`/`CShaderc`/`CSPIRVCross` resolve real distro packages
via pkg-config at build time — nothing to vendor there, same as any other
app linking `libvulkan-dev` etc. `CWgpu` is different: wgpu-native has no
distro package, so instead of relying on pkg-config finding *some* build of
it wherever it happens to be on the machine, `libwgpu_native.so` + headers
are vendored into `Dependencies/linux/` (committed to the repo) and linked
directly — see "wgpu-native" below.

## Install once per machine

```
sudo apt install libvulkan-dev libwayland-dev libxcb1-dev libx11-dev \
                  libshaderc-dev libspirv-cross-c-shared-dev
```

* `libvulkan-dev` — the Vulkan loader + headers (`vulkan.pc`).
* `libwayland-dev` / `libxcb1-dev` / `libx11-dev` — WSI headers.
  `Sources/CVulkanLinux/shim.h` auto-detects whichever of
  `wayland-client.h` / `xcb/xcb.h` / `X11/Xlib.h` are installed and defines
  the matching `VK_USE_PLATFORM_*_KHR`, so surface creation for that
  windowing backend becomes available in `vulkan.h`. Installing all three
  gets Wayland, XCB, and Xlib surface support in one build.
* `libshaderc-dev` — GLSL -> SPIR-V compiler (`shaderc.pc`).
* `libspirv-cross-c-shared-dev` — SPIR-V -> MSL/HLSL/GLSL cross-compiler
  (`spirv-cross-c-shared.pc`).

## wgpu-native (no distro package — vendored, not pkg-config)

No distro packages wgpu-native, so it needs a one-time local build instead
of `apt install`. Building it requires Rust (via [rustup](https://rustup.rs))
and `libclang-dev` (wgpu-native's build script uses `bindgen` to generate
FFI bindings from the WebGPU C headers, which needs a real libclang — not
just the bare `.so`, but the resource headers like `stddef.h` it ships
alongside):

```
sudo apt install libclang-dev
python3 scripts/build_wgpu.py --prefix Dependencies/linux
```

This builds wgpu-native for the host triple and copies the result here:

* `Dependencies/linux/lib/libwgpu_native.so`
* `Dependencies/linux/include/{wgpu.h,webgpu.h}` (also duplicated into
  `Sources/CWgpuLinux/include/` — SwiftPM's C target header search paths
  are private to the target that declares them and don't propagate to
  importers, so the headers `import CWgpu` sees have to live under
  `CWgpu`'s own `publicHeadersPath`, not just in `Dependencies/linux/`)

`CWgpu`'s Linux target links `Dependencies/linux/lib` directly (`-L`/`-l` +
an `-rpath` back to that same directory) instead of going through
pkg-config — `wgpu-native.pc` still gets written by the script (unused by
Package.swift now) but there's no dependency on it being on
`PKG_CONFIG_PATH`. If you bump `WGPU_REF` in `scripts/build_wgpu.py`, rerun
the command above to refresh the vendored copy.

## Building the package

```
swift build
```

`Package.swift` detects Linux automatically (`#if os(Linux)` inside the
manifest itself) and adds the Linux `CVulkan`/`CShaderc`/`CSPIRVCross`/`CWgpu`
targets — no extra flags needed. (Cross-compiling to Android instead is an
explicit opt-in: `ANDROID_BUILD=1 swift build ...`, since that's always a
cross-compile and can't be auto-detected from the host OS.)
