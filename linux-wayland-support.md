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
`CSPIRVCross` resolve real distro packages via pkg-config on Linux.
`CWgpu` (no distro package) is vendored into `Dependencies/linux/` and
linked directly instead — the earlier version of this note said "resolve
via pkg-config" for `CWgpu` too and called this "done" without mentioning
that meant a mandatory unversioned manual build+install step outside the
repo (`sudo python3 scripts/build_wgpu.py`) with nothing checked in; that
overstated it. Verified end to end (clean shell, no `PKG_CONFIG_PATH`
needed for `CWgpu` specifically) except for `SulphurGeometry` (separate
repo, blocks the final link with `import simd` — Apple-only, not fixed
here — though that import turned out to be dead weight too, see
`NucleantThorVG/plans/linux-webgpu.md`).

## Pre-build commands (Linux, one-time per machine)

```
# System libs: Vulkan loader + WSI headers, shaderc, spirv-cross,
# libclang (needed to build wgpu-native below).
sudo apt-get update && sudo apt-get -y install \
  libvulkan-dev libwayland-dev libxcb1-dev libx11-dev \
  libshaderc-dev libspirv-cross-c-shared-dev \
  libclang-dev

# wgpu-native has no distro package: build it once and vendor it into the
# repo (Dependencies/linux/) — CWgpu links that directly, no PKG_CONFIG_PATH
# needed afterwards.
python3 scripts/build_wgpu.py --prefix Dependencies/linux

# Then just:
swift build
```

Full details in `Dependencies/linux/README.md`.