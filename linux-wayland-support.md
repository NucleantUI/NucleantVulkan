# Linux Spport

organise current /Depedencies soo we got 

/Depedencies/macos/*current_frameworks*
/Depedencies/linux


and update Package.swift soo macos binary targets paths matches

* add linux/wayland support

ensure linux deps for:
* shaderc 
* spirv-cross
* wgpu

i guess thats it for this lib..

## Status: done for this package

`Package.swift` now auto-detects Linux (`#if os(Linux)`, no build flags
needed — the old `-DLINUX_BUILD` scheme was dead code, since `-Xswiftc`
never reaches Package.swift's own compilation). `CVulkan`/`CShaderc`/
`CSPIRVCross`/`CWgpu` all resolve and compile on Linux via pkg-config.
Verified end to end except for `SulphurGeometry` (separate repo, blocks the
final link with `import simd` — Apple-only, not fixed here).

## Pre-build commands (Linux, one-time per machine)

```
# System libs: Vulkan loader + WSI headers, shaderc, spirv-cross,
# libclang (needed to build wgpu-native below).
sudo apt-get update && sudo apt-get -y install \
  libvulkan-dev libwayland-dev libxcb1-dev libx11-dev \
  libshaderc-dev libspirv-cross-c-shared-dev \
  libclang-dev

# wgpu-native has no distro package: build + install it once.
# Installs libwgpu_native.so + headers + wgpu-native.pc under /usr/local
# (sudo needed for that prefix) so pkg-config finds it automatically.
sudo python3 scripts/build_wgpu.py
# Or, without sudo, install under your home dir and point pkg-config at it:
#   python3 scripts/build_wgpu.py --prefix ~/.local
#   export PKG_CONFIG_PATH="$HOME/.local/lib/pkgconfig:$PKG_CONFIG_PATH"

# Then just:
swift build
```

Full details in `Dependencies/linux/README.md`.