#!/usr/bin/env python3
"""Cross-compile shaderc and spirv-cross for WebAssembly (wasm32-unknown-wasip1).

The wasm counterpart of build_shader_tools.py (Android). A wasm build has no
system package manager and no xcframeworks, so the two are vendored as static
archives, the way Android vendors its .so files:

    Dependencies/wasm/lib/libshaderc_combined.a
    Dependencies/wasm/lib/libspirv-cross-c.a   (+ the libspirv-cross-*.a it needs)
    Sources/CShadercWasm/include/shaderc/*.h
    Sources/CSPIRVCrossWasm/include/spirv_cross_c.h

Static, not shared: wasm has no dynamic loader in the browser, so everything
links into the one module the app ships.

The compiler is the clang of the Swift toolchain that matches the installed
wasm Swift SDK, and the sysroot is that SDK's WASI.sdk — the same libc and
libc++ the Swift side links against, so the archives and the Swift objects
agree on every C/C++ runtime detail.

One wrinkle: the SDK's libc++ is built without threads (`_LIBCPP_HAS_THREADS
0`), and glslang guards its process-wide init with a `std::mutex`. A wasm
module in the browser runs on one thread, so a lock that never contends is
exactly right; a force-included header supplies that `std::mutex` (see
`MUTEX_SHIM`). Nothing else in shaderc or spirv-cross needs threads.

Sources are cloned into scripts/.work (shared with the other build scripts) so
repeated runs are incremental. Use --clean to start fresh.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# --- Paths -----------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
PACKAGE_ROOT = SCRIPT_DIR.parent
DEPENDENCIES_DIR = PACKAGE_ROOT / "Dependencies"
DEFAULT_WORK_DIR = SCRIPT_DIR / ".work"
WASM_LIB_DIR = DEPENDENCIES_DIR / "wasm" / "lib"

SOURCES_DIR = PACKAGE_ROOT / "Sources"
SHADERC_TARGET_INCLUDE = SOURCES_DIR / "CShadercWasm" / "include"
SPIRV_CROSS_TARGET_INCLUDE = SOURCES_DIR / "CSPIRVCrossWasm" / "include"

# --- Upstream sources (same pins as the Android build) ---------------------

SHADERC_REPO = "https://github.com/google/shaderc.git"
SHADERC_REF = "v2024.3"

SPIRV_CROSS_REPO = "https://github.com/KhronosGroup/SPIRV-Cross.git"
SPIRV_CROSS_REF = "vulkan-sdk-1.3.290.0"

TRIPLE = "wasm32-unknown-wasip1"

# Force-included into every C++ translation unit. libc++ without threads
# declares no std::mutex; glslang's ShaderLang.cpp and shaderc_util both use
# one around one-time init. A single-threaded wasm module never contends, so
# lock/unlock are no-ops.
MUTEX_SHIM = """\
#pragma once
#ifdef __cplusplus
#include <__config>
#if !_LIBCPP_HAS_THREADS
_LIBCPP_BEGIN_NAMESPACE_STD
class mutex {
public:
    constexpr mutex() noexcept = default;
    mutex(const mutex&) = delete;
    mutex& operator=(const mutex&) = delete;
    void lock() {}
    bool try_lock() { return true; }
    void unlock() {}
};
_LIBCPP_END_NAMESPACE_STD
#endif
#endif
"""

VERSION_RE = re.compile(r"(\d+\.\d+(?:\.\d+)?)")


def log(message: str) -> None:
    print(f"[build_shader_tools_wasm] {message}", flush=True)


def run(cmd: list[str], cwd: Path | None = None, env: dict | None = None) -> None:
    log("$ " + " ".join(str(c) for c in cmd))
    subprocess.check_call(cmd, cwd=cwd, env=env)


def require(tool: str) -> None:
    if shutil.which(tool) is None:
        sys.exit(f"error: required tool not found on PATH: {tool}")


def sync_repo(repo: str, ref: str, dest: Path) -> None:
    require("git")
    if (dest / ".git").is_dir():
        log(f"updating {dest.name} -> {ref}")
        run(["git", "fetch", "--tags", "--depth", "1", "origin", ref], cwd=dest)
        run(["git", "checkout", "--force", ref], cwd=dest)
    else:
        dest.parent.mkdir(parents=True, exist_ok=True)
        log(f"cloning {repo} @ {ref}")
        run(["git", "clone", "--depth", "1", "--branch", ref, repo, str(dest)])


# --- Toolchain -------------------------------------------------------------


def find_wasm_sdk(explicit: Path | None) -> Path:
    """The WASI.sdk sysroot inside the installed wasm Swift SDK bundle."""
    if explicit is not None:
        return explicit.resolve()
    roots = [
        Path.home() / "Library" / "org.swift.swiftpm" / "swift-sdks",
        Path.home() / ".swiftpm" / "swift-sdks",
    ]
    for root in roots:
        for sysroot in sorted(root.glob(f"*_wasm.artifactbundle/*/{TRIPLE}/WASI.sdk"), reverse=True):
            return sysroot
    sys.exit(
        "error: no wasm Swift SDK found.\n"
        "  Install one (https://www.swift.org/documentation/articles/wasm-getting-started.html)\n"
        "  or pass --sysroot <...>/wasm32-unknown-wasip1/WASI.sdk."
    )


def find_toolchain_bin(explicit: Path | None, sysroot: Path) -> Path:
    """The usr/bin of the Swift toolchain whose version matches the SDK.

    The SDK only works with its own toolchain, and its clang is the one that
    knows the wasm32-wasip1 target the SDK's libc++ was built with.
    """
    if explicit is not None:
        return explicit.resolve()
    match = VERSION_RE.search(str(sysroot))
    version = match.group(1) if match else None
    candidates = []
    for base in (Path.home() / "Library" / "Developer" / "Toolchains", Path("/Library/Developer/Toolchains")):
        if version:
            candidates.append(base / f"swift-{version}-RELEASE.xctoolchain" / "usr" / "bin")
    candidates.append(Path.home() / ".swiftly" / "bin")
    for candidate in candidates:
        if (candidate / "clang").is_file() and (candidate / "wasm-ld").is_file():
            return candidate
    sys.exit(
        f"error: no Swift {version} toolchain with clang + wasm-ld found.\n"
        f"  Install it (`swiftly install {version}`) or pass --toolchain <toolchain>/usr/bin."
    )


# Runs right after SPIRV-Tools' own project() call. Its CMakeLists stops with
# "Your platform 'WASI' is not supported!" — it lists every OS it knows and
# WASI isn't one. The only thing the per-OS define changes in the sources is
# whether print.cpp emits terminal colour codes, which is the Emscripten
# answer for any wasm target, so the WASI build takes that branch. Scoped to
# the SPIRV-Tools directory; nothing else sees the changed name.
SPIRV_TOOLS_PROJECT_INCLUDE = """\
if(CMAKE_SYSTEM_NAME STREQUAL "WASI")
  set(CMAKE_SYSTEM_NAME Emscripten)
endif()
"""


def write_toolchain_file(work_dir: Path, bin_dir: Path, sysroot: Path) -> Path:
    shim = work_dir / "wasm" / "wasi_single_thread_mutex.h"
    shim.parent.mkdir(parents=True, exist_ok=True)
    shim.write_text(MUTEX_SHIM)
    (work_dir / "wasm" / "spirv_tools_wasi.cmake").write_text(SPIRV_TOOLS_PROJECT_INCLUDE)
    path = work_dir / "wasm" / "wasm32-wasip1.cmake"
    path.write_text(
        f"""\
set(CMAKE_SYSTEM_NAME WASI)
set(CMAKE_SYSTEM_VERSION 1)
set(CMAKE_SYSTEM_PROCESSOR wasm32)
set(CMAKE_C_COMPILER "{bin_dir / 'clang'}")
set(CMAKE_CXX_COMPILER "{bin_dir / 'clang++'}")
set(CMAKE_AR "{bin_dir / 'llvm-ar'}" CACHE FILEPATH "")
set(CMAKE_RANLIB "{bin_dir / 'llvm-ranlib'}" CACHE FILEPATH "")
set(CMAKE_C_COMPILER_TARGET {TRIPLE})
set(CMAKE_CXX_COMPILER_TARGET {TRIPLE})
set(CMAKE_SYSROOT "{sysroot}")
set(CMAKE_CXX_FLAGS_INIT "-include {shim} -fno-exceptions")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
"""
    )
    return path


def cmake_configure_build(
    src: Path,
    build_dir: Path,
    toolchain: Path,
    extra: list[str],
    targets: list[str],
    jobs: int,
) -> None:
    build_dir.mkdir(parents=True, exist_ok=True)
    run(
        [
            "cmake",
            "-S", str(src),
            "-B", str(build_dir),
            "-G", "Ninja",
            f"-DCMAKE_TOOLCHAIN_FILE={toolchain}",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=OFF",
        ]
        + extra
    )
    command = ["cmake", "--build", str(build_dir), "--parallel", str(jobs)]
    for target in targets:
        command += ["--target", target]
    run(command)


# --- shaderc ---------------------------------------------------------------


def build_shaderc(work_dir: Path, toolchain: Path, jobs: int) -> None:
    src = work_dir / "shaderc"
    sync_repo(SHADERC_REPO, SHADERC_REF, src)

    # shaderc vendors glslang / SPIRV-Tools / SPIRV-Headers by checkout rather
    # than submodule; this fetches them at the revisions shaderc pins.
    sync_script = src / "utils" / "git-sync-deps"
    if sync_script.is_file() and not (src / "third_party" / "glslang").is_dir():
        run([sys.executable, str(sync_script)], cwd=src)

    build_dir = work_dir / "build" / "shaderc-wasm32"
    cmake_configure_build(
        src, build_dir, toolchain,
        [
            "-DSHADERC_SKIP_TESTS=ON",
            "-DSHADERC_SKIP_EXAMPLES=ON",
            "-DSHADERC_SKIP_COPYRIGHT_CHECK=ON",
            "-DSPIRV_SKIP_EXECUTABLES=ON",
            "-DSPIRV_SKIP_TESTS=ON",
            "-DENABLE_GLSLANG_BINARIES=OFF",
            "-DGLSLANG_TESTS=OFF",
            f"-DCMAKE_PROJECT_spirv-tools_INCLUDE={toolchain.parent / 'spirv_tools_wasi.cmake'}",
        ],
        # libshaderc_combined bundles shaderc, shaderc_util, glslang and
        # SPIRV-Tools(-opt) into one archive — one -l for SwiftPM.
        ["shaderc_combined"],
        jobs,
    )

    _install_lib(_find_one(build_dir, "libshaderc_combined.a"))
    # Into the target's own include/, for the same publicHeadersPath reason
    # build_shader_tools.py gives for Android.
    _install_header_tree(src / "libshaderc" / "include" / "shaderc",
                         SHADERC_TARGET_INCLUDE / "shaderc")


# --- spirv-cross -----------------------------------------------------------


def build_spirv_cross(work_dir: Path, toolchain: Path, jobs: int) -> None:
    src = work_dir / "SPIRV-Cross"
    sync_repo(SPIRV_CROSS_REPO, SPIRV_CROSS_REF, src)

    build_dir = work_dir / "build" / "spirv-cross-wasm32"
    cmake_configure_build(
        src, build_dir, toolchain,
        [
            "-DSPIRV_CROSS_SHARED=OFF",
            "-DSPIRV_CROSS_STATIC=ON",
            "-DSPIRV_CROSS_CLI=OFF",
            "-DSPIRV_CROSS_ENABLE_TESTS=OFF",
            # No C++ exceptions in the SDK's libc++abi: spirv-cross reports
            # its errors through the C API's error callback instead.
            "-DSPIRV_CROSS_EXCEPTIONS_TO_ASSERTIONS=ON",
        ],
        [],
        jobs,
    )

    for name in (
        "libspirv-cross-c.a",
        "libspirv-cross-core.a",
        "libspirv-cross-glsl.a",
        "libspirv-cross-msl.a",
        "libspirv-cross-hlsl.a",
        "libspirv-cross-cpp.a",
        "libspirv-cross-reflect.a",
        "libspirv-cross-util.a",
    ):
        _install_lib(_find_one(build_dir, name))
    _install_header(src / "spirv_cross_c.h", SPIRV_CROSS_TARGET_INCLUDE)


# --- install helpers -------------------------------------------------------


def _find_one(root: Path, name: str) -> Path:
    matches = sorted(root.rglob(name))
    if not matches:
        sys.exit(f"error: {name} not produced under {root}")
    return matches[0]


def _install_lib(lib: Path) -> None:
    WASM_LIB_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copy2(lib, WASM_LIB_DIR / lib.name)
    log(f"installed -> {WASM_LIB_DIR / lib.name}")


def _install_header(header: Path, dest_dir: Path) -> None:
    dest_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(header, dest_dir / header.name)
    log(f"header installed -> {dest_dir / header.name}")


def _install_header_tree(src_dir: Path, dest_dir: Path) -> None:
    """C headers only — see build_shader_tools.py for why not *.hpp."""
    dest_dir.mkdir(parents=True, exist_ok=True)
    for header in sorted(src_dir.glob("*.h")):
        shutil.copy2(header, dest_dir / header.name)
    log(f"headers installed -> {dest_dir}")


# --- Entry point -----------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--only", choices=["shaderc", "spirv-cross"],
                        help="build just one of the two")
    parser.add_argument("--sysroot", type=Path, default=None,
                        help="WASI.sdk of the wasm Swift SDK (default: the installed one)")
    parser.add_argument("--toolchain", type=Path, default=None,
                        help="usr/bin of the matching Swift toolchain (default: found by version)")
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK_DIR)
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--clean", action="store_true", help="delete the wasm build dirs first")
    args = parser.parse_args()

    require("cmake")
    require("ninja")
    work_dir = args.work_dir.resolve()
    sysroot = find_wasm_sdk(args.sysroot)
    bin_dir = find_toolchain_bin(args.toolchain, sysroot)
    log(f"sysroot   {sysroot}")
    log(f"toolchain {bin_dir}")

    if args.clean:
        for name in ("shaderc-wasm32", "spirv-cross-wasm32"):
            shutil.rmtree(work_dir / "build" / name, ignore_errors=True)

    toolchain = write_toolchain_file(work_dir, bin_dir, sysroot)
    if args.only in (None, "shaderc"):
        build_shaderc(work_dir, toolchain, args.jobs)
    if args.only in (None, "spirv-cross"):
        build_spirv_cross(work_dir, toolchain, args.jobs)
    log("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
