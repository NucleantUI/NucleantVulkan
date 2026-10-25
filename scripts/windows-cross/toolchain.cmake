# CMake toolchain for cross-compiling to x86_64-pc-windows-msvc from Linux
# (scripts/windows-cross/Dockerfile): clang-cl, lld-link and the llvm-* tools
# in place of MSVC's, against the CRT and Windows SDK cargo-xwin caches in
# $XWIN_CACHE_DIR — one copy for the cargo and CMake builds both.
#
# Modelled on the toolchain cargo-xwin writes for itself, plus the resource
# compiler, manifest tool and MASM assembler, which Vulkan-Loader's Windows
# build uses and that one leaves out.

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR AMD64)

# Full paths: a bare name in a FILEPATH entry is taken relative to the build
# directory by projects that configure nested builds (Vulkan-Loader's
# update_deps.py).
find_program(_clang_cl clang-cl REQUIRED)
find_program(_lld_link lld-link REQUIRED)
find_program(_llvm_lib llvm-lib REQUIRED)
find_program(_llvm_rc llvm-rc REQUIRED)
find_program(_llvm_mt llvm-mt REQUIRED)
find_program(_llvm_ml llvm-ml REQUIRED)
set(CMAKE_C_COMPILER ${_clang_cl})
set(CMAKE_CXX_COMPILER ${_clang_cl})
set(CMAKE_LINKER ${_lld_link})
set(CMAKE_AR ${_llvm_lib})
set(CMAKE_RC_COMPILER ${_llvm_rc})
set(CMAKE_MT ${_llvm_mt})
set(CMAKE_ASM_MASM_COMPILER ${_llvm_ml})

# The DLL C runtime (/MD), which Swift on Windows uses too.
set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreadedDLL CACHE STRING "")
set(CMAKE_POLICY_DEFAULT_CMP0091 NEW)

set(_xwin "$ENV{XWIN_CACHE_DIR}/xwin")
set(_includes
    ${_xwin}/crt/include
    ${_xwin}/sdk/include/ucrt
    ${_xwin}/sdk/include/um
    ${_xwin}/sdk/include/shared
    ${_xwin}/sdk/include/winrt)
set(_libpaths
    ${_xwin}/crt/lib/x86_64
    ${_xwin}/sdk/lib/um/x86_64
    ${_xwin}/sdk/lib/ucrt/x86_64)

set(_compile_flags --target=x86_64-pc-windows-msvc -Wno-unused-command-line-argument -fuse-ld=lld-link)
set(_rc_flags "")
foreach(dir IN LISTS _includes)
    list(APPEND _compile_flags /imsvc ${dir})
    list(APPEND _rc_flags /I ${dir})
endforeach()
set(_link_flags /manifest:no)
foreach(dir IN LISTS _libpaths)
    list(APPEND _link_flags /libpath:${dir})
endforeach()
list(JOIN _compile_flags " " _compile_flags)
list(JOIN _rc_flags " " _rc_flags)
list(JOIN _link_flags " " _link_flags)

set(CMAKE_C_FLAGS_INIT "${_compile_flags}")
set(CMAKE_CXX_FLAGS_INIT "${_compile_flags} /EHsc")
set(CMAKE_RC_FLAGS_INIT "${_rc_flags}")
set(CMAKE_ASM_MASM_FLAGS_INIT "--m64")
set(CMAKE_EXE_LINKER_FLAGS_INIT "${_link_flags}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${_link_flags}")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "${_link_flags}")

set(CMAKE_TRY_COMPILE_CONFIGURATION Release)

# Unix paths start with "/", which clang-cl and llvm-ml read as an option
# ("/opt/..." as /o): the rules hand them the source after "--" and "/Ta".
set(CMAKE_USER_MAKE_RULES_OVERRIDE "${CMAKE_CURRENT_LIST_DIR}/override.cmake")
