# Linux dependencies

Unlike macOS/iOS (Dependencies/macos/, vendored xcframeworks committed into
the repo), Linux dependencies are discovered at build time via pkg-config —
nothing is vendored here. This mirrors how `CVulkan` already resolves the
system Vulkan loader.

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

## wgpu-native (no distro package)

No distro packages wgpu-native, so it needs a one-time local build+install
instead of `apt install`. Building it requires Rust (via
[rustup](https://rustup.rs)) and `libclang-dev` (wgpu-native's build script
uses `bindgen` to generate FFI bindings from the WebGPU C headers, which
needs a real libclang — not just the bare `.so`, but the resource headers
like `stddef.h` it ships alongside):

```
sudo apt install libclang-dev
python3 scripts/build_wgpu.py
```

This builds wgpu-native for the host triple and installs
`libwgpu_native.so` + headers + a generated `wgpu-native.pc` under
`/usr/local` by default (needs `sudo` for that prefix — or pass
`--prefix ~/.local` and export
`PKG_CONFIG_PATH=$HOME/.local/lib/pkgconfig:$PKG_CONFIG_PATH` before
building the Swift package, since `~/.local/lib/pkgconfig` isn't a default
pkg-config search path).

## Building the package

```
swift build
```

`Package.swift` detects Linux automatically (`#if os(Linux)` inside the
manifest itself) and adds the Linux `CVulkan`/`CShaderc`/`CSPIRVCross`/`CWgpu`
targets — no extra flags needed. (Cross-compiling to Android instead is an
explicit opt-in: `ANDROID_BUILD=1 swift build ...`, since that's always a
cross-compile and can't be auto-detected from the host OS.)
