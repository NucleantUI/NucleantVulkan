// CSPIRVCross Android shim — vendored spirv-cross, not a system package.
//
// The Linux target resolves this through spirv-cross-c-shared.pc, whose
// includedir points straight at .../include/spirv_cross. There is no .pc file
// on Android, so the header is reached through the vendored include root and
// keeps the same unprefixed name.

#ifndef CSPIRVCrossAndroid_shim_h
#define CSPIRVCrossAndroid_shim_h

#include "spirv_cross_c.h"

#endif /* CSPIRVCrossAndroid_shim_h */
