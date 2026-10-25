# Included by CMake after its default rules (CMAKE_USER_MAKE_RULES_OVERRIDE in
# toolchain.cmake): the compile rules pass the source where clang-cl and
# llvm-ml cannot take a Unix path for an option.
string(REPLACE "-c <SOURCE>" "-c -- <SOURCE>" CMAKE_C_COMPILE_OBJECT "${CMAKE_C_COMPILE_OBJECT}")
string(REPLACE "-c <SOURCE>" "-c -- <SOURCE>" CMAKE_CXX_COMPILE_OBJECT "${CMAKE_CXX_COMPILE_OBJECT}")
string(REPLACE "<SOURCE>" "/Ta <SOURCE>" CMAKE_ASM_MASM_COMPILE_OBJECT "${CMAKE_ASM_MASM_COMPILE_OBJECT}")
# cmcldeps, which CMake's Ninja rules run around rc, exists only on Windows.
if(NOT CMAKE_HOST_WIN32)
    set(CMAKE_NINJA_CMCLDEPS_RC 0)
endif()
