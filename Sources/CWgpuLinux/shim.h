// CWgpu Linux shim — wgpu-native via pkg-config (wgpu-native.pc).
// No distro packages wgpu-native, so there's a build step first:
// scripts/build_wgpu_linux.py builds it and installs wgpu.h + webgpu.h flat
// alongside a wgpu-native.pc pkg-config file (same header layout as the
// macOS/iOS xcframeworks assembled by scripts/build_wgpu.py).

#ifndef CWgpuLinux_shim_h
#define CWgpuLinux_shim_h

#include "wgpu.h"

#endif /* CWgpuLinux_shim_h */
