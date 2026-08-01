// CShaderc Android shim — vendored shaderc, not a system package.
//
// Android has no pkg-config and no distro to resolve libshaderc-dev from, so
// unlike CShadercLinux this is a compiled target whose header and library
// search paths point at Dependencies/android/. Same C API surface either way.

#ifndef CShadercAndroid_shim_h
#define CShadercAndroid_shim_h

#include <shaderc/shaderc.h>

#endif /* CShadercAndroid_shim_h */
