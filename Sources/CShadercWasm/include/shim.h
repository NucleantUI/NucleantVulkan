// CShaderc wasm shim — vendored shaderc, built for wasm32-wasip1.
//
// The real shaderc (glslang + SPIRV-Tools), compiled by
// scripts/build_shader_tools_wasm.py into a static archive under
// Dependencies/wasm/lib and linked into the module, so GLSL compiles to the
// same SPIR-V in the browser as on every other platform. Same C API surface.

#ifndef CShadercWasm_shim_h
#define CShadercWasm_shim_h

#include <shaderc/shaderc.h>

#endif /* CShadercWasm_shim_h */
