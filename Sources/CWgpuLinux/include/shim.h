// CWgpu Linux shim — vendored wgpu-native (Dependencies/linux/).
// No distro packages wgpu-native, so it's built and vendored here instead
// of resolved from the system: scripts/build_wgpu.py --prefix
// Dependencies/linux builds it and copies libwgpu_native.so + wgpu.h +
// webgpu.h into Dependencies/linux/ (same header layout as the macOS/iOS
// xcframeworks assembled by the same script). See
// Dependencies/linux/README.md.

#ifndef CWgpuLinux_shim_h
#define CWgpuLinux_shim_h

#include "wgpu.h"

#endif /* CWgpuLinux_shim_h */
