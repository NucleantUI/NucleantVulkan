// CSPIRVCross Linux shim — system spirv-cross via pkg-config
// (libspirv-cross-c-shared-dev). Its spirv-cross-c-shared.pc points
// includedir straight at .../include/spirv_cross, so the header is reachable
// unprefixed — same name as the Apple xcframework's vendored copy.

#ifndef CSPIRVCrossLinux_shim_h
#define CSPIRVCrossLinux_shim_h

#include "spirv_cross_c.h"

#endif /* CSPIRVCrossLinux_shim_h */
