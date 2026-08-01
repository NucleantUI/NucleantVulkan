#!/usr/bin/env python3
"""Cross-compile shaderc and spirv-cross for Android.

These two have no Android story anywhere else in the package: on Linux they are
apt packages resolved through pkg-config (CShadercLinux / CSPIRVCrossLinux), and
on Apple they are prebuilt xcframeworks under Dependencies/macos. Android has
neither a distro nor xcframework support, so they are vendored per ABI the same
way wgpu-native is — see build_wgpu.py, whose Android mode this mirrors.

Layout produced (what the `.android` branch of Package.swift points -I/-L at):

    Dependencies/android/<abi>/lib/libshaderc_shared.so
    Dependencies/android/<abi>/lib/libspirv-cross-c-shared.so
    Sources/CShadercAndroid/include/shaderc/*.h
    Sources/CSPIRVCrossAndroid/include/spirv_cross_c.h

Libraries are per-ABI; headers are ABI-independent and vendored into the C
targets themselves, because SwiftPM only exposes a target's publicHeadersPath
to importers.

Both are plain CMake projects, cross-compiled through the NDK's own
android.toolchain.cmake rather than a hand-rolled toolchain file — that is what
keeps the ABI/API/STL choices consistent with everything else in the app.

Sources are cloned into scripts/.work (shared with build_wgpu.py /
build_vulkan.py) so repeated runs are incremental. Use --clean to start fresh.
"""

from __future__ import annotations

import argparse
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

# --- Paths -----------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
PACKAGE_ROOT = SCRIPT_DIR.parent
DEPENDENCIES_DIR = PACKAGE_ROOT / "Dependencies"
DEFAULT_WORK_DIR = SCRIPT_DIR / ".work"

# --- Upstream sources ------------------------------------------------------

SHADERC_REPO = "https://github.com/google/shaderc.git"
SHADERC_REF = "v2024.3"

SPIRV_CROSS_REPO = "https://github.com/KhronosGroup/SPIRV-Cross.git"
SPIRV_CROSS_REF = "vulkan-sdk-1.3.290.0"

# Matches [tool.kivy-school.android] min_api, pinned at the Swift Android SDK's
# floor — a lower level here would produce .so files the app cannot load.
ANDROID_API_DEFAULT = 28

ANDROID_ABIS = ("arm64-v8a", "x86_64", "armeabi-v7a")

# Headers are vendored into each C target's publicHeadersPath rather than a
# shared Dependencies/android/include: SwiftPM only exposes publicHeadersPath
# to importers, so an external -I would compile the target's own stub.c and
# then fail the moment anything did `import CShaderc`.
SOURCES_DIR = PACKAGE_ROOT / "Sources"
SHADERC_TARGET_INCLUDE = SOURCES_DIR / "CShadercAndroid" / "include"
SPIRV_CROSS_TARGET_INCLUDE = SOURCES_DIR / "CSPIRVCrossAndroid" / "include"


def log(message: str) -> None:
    print(f"[build_shader_tools] {message}", flush=True)


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


# --- NDK -------------------------------------------------------------------



def find_ndk(explicit: Path | None) -> Path:
    """Locate an Android NDK. Same resolution order as build_wgpu.py: nothing
    is hardcoded, because ksproject provisions the NDK and exports it, and
    Android Studio / CI images / distro packages all differ."""
    if explicit is not None:
        return explicit.resolve()
    # Env first: this is what ksproject exports when *it* drives the build.
    for var in ("ANDROID_NDK_HOME", "ANDROID_NDK_ROOT", "NDK_HOME"):
        value = os.environ.get(var)
        if value:
            return Path(value).resolve()
    sys.exit(
        "error: no Android NDK given.\n"
        "  Pass --ndk <path>, or set ANDROID_NDK_HOME — ksproject exports it\n"
        "  when it drives the build; resolve it yourself with\n"
        "  `uv run ksproject android get-path ndk`."
    )


def find_cmake(explicit: Path | None) -> Path:
    """Locate cmake, preferring the SDK's own copy.

    The Android SDK ships a pinned cmake under <sdk>/cmake/<version>/bin, and
    many machines that can build Android apps have no system cmake at all — so
    falling back to it (rather than requiring one on PATH) is what makes this
    script run wherever ksproject's toolchain already works.
    """
    if explicit is not None:
        return explicit.resolve()
    for var in ("ANDROID_SDK_ROOT", "ANDROID_HOME"):
        value = os.environ.get(var)
        if not value:
            continue
        cmake_root = Path(value) / "cmake"
        if cmake_root.is_dir():
            versions = sorted(p for p in cmake_root.iterdir() if p.is_dir())
            for version in reversed(versions):
                candidate = version / "bin" / "cmake"
                if candidate.is_file():
                    return candidate.resolve()
    system = shutil.which("cmake")
    if system:
        return Path(system)
    sys.exit(
        "error: cmake not found.\n"
        "  Pass --cmake <path>, install one, or set ANDROID_SDK_ROOT so the "
        "SDK's bundled cmake can be used."
    )


def find_ninja(cmake: Path) -> Path:
    """Ninja sits beside the SDK's cmake; otherwise take one from PATH."""
    sibling = cmake.parent / "ninja"
    if sibling.is_file():
        return sibling
    system = shutil.which("ninja")
    if system:
        return Path(system)
    sys.exit("error: ninja not found (needed by the -G Ninja generator).")


def toolchain_file(ndk: Path) -> Path:
    path = ndk / "build" / "cmake" / "android.toolchain.cmake"
    if not path.is_file():
        sys.exit(f"error: NDK cmake toolchain not found: {path}")
    return path


def cmake_configure_build(
    cmake: Path,
    ninja: Path,
    src: Path,
    build_dir: Path,
    ndk: Path,
    abi: str,
    api: int,
    extra: list[str],
    jobs: int,
) -> None:
    build_dir.mkdir(parents=True, exist_ok=True)
    run(
        [
            str(cmake),
            "-S", str(src),
            "-B", str(build_dir),
            "-G", "Ninja",
            f"-DCMAKE_TOOLCHAIN_FILE={toolchain_file(ndk)}",
            f"-DANDROID_ABI={abi}",
            f"-DANDROID_PLATFORM=android-{api}",
            # c++_shared, not c++_static: several .so files in the APK link the
            # C++ runtime, and separate static copies would give each its own
            # std:: state. Gradle already stages libc++_shared.so into jniLibs.
            "-DANDROID_STL=c++_shared",
            "-DCMAKE_BUILD_TYPE=Release",
            f"-DCMAKE_MAKE_PROGRAM={ninja}",
        ]
        + extra
    )
    run([str(cmake), "--build", str(build_dir), "--parallel", str(jobs)])


# --- shaderc ---------------------------------------------------------------


def build_shaderc(cmake: Path, ninja: Path, work_dir: Path, ndk: Path, abi: str, api: int, jobs: int) -> None:
    src = work_dir / "shaderc"
    sync_repo(SHADERC_REPO, SHADERC_REF, src)

    # shaderc vendors glslang / SPIRV-Tools / SPIRV-Headers by checkout rather
    # than submodule; this script fetches them at the revisions shaderc pins.
    sync_script = src / "utils" / "git-sync-deps"
    if sync_script.is_file() and not (src / "third_party" / "glslang").is_dir():
        run([sys.executable, str(sync_script)], cwd=src)

    build_dir = work_dir / "build" / f"shaderc-{abi}"
    cmake_configure_build(
        cmake, ninja, src, build_dir, ndk, abi, api,
        [
            "-DSHADERC_SKIP_TESTS=ON",
            "-DSHADERC_SKIP_EXAMPLES=ON",
            "-DSHADERC_SKIP_COPYRIGHT_CHECK=ON",
            # The Swift target links libshaderc_shared.so; without this only
            # the static archive is produced.
            "-DBUILD_SHARED_LIBS=OFF",
            "-DSHADERC_ENABLE_SHARED_CRT=ON",
        ],
        jobs,
    )

    lib = _find_one(build_dir, "libshaderc_shared.so")
    _install_lib(lib, abi)
    # Into the target's own include/, NOT Dependencies/android/include: a
    # header search path set via cSettings is private to the declaring target
    # and does not reach importers building the Clang module, so only
    # publicHeadersPath works here. Same reason CWgpuLinux vendors wgpu.h.
    _install_header_tree(src / "libshaderc" / "include" / "shaderc",
                         SHADERC_TARGET_INCLUDE / "shaderc")


# --- spirv-cross -----------------------------------------------------------


def build_spirv_cross(cmake: Path, ninja: Path, work_dir: Path, ndk: Path, abi: str, api: int, jobs: int) -> None:
    src = work_dir / "SPIRV-Cross"
    sync_repo(SPIRV_CROSS_REPO, SPIRV_CROSS_REF, src)

    build_dir = work_dir / "build" / f"spirv-cross-{abi}"
    cmake_configure_build(
        cmake, ninja, src, build_dir, ndk, abi, api,
        [
            "-DSPIRV_CROSS_SHARED=ON",
            "-DSPIRV_CROSS_STATIC=OFF",
            "-DSPIRV_CROSS_CLI=OFF",
            "-DSPIRV_CROSS_ENABLE_TESTS=OFF",
        ],
        jobs,
    )

    lib = _find_one(build_dir, "libspirv-cross-c-shared.so")
    _install_lib(lib, abi)
    # Beside shim.h, which includes it unprefixed — matching the Linux shim's
    # spelling. Vendored into the target for the same publicHeadersPath reason
    # as shaderc above.
    _install_header(src / "spirv_cross_c.h", SPIRV_CROSS_TARGET_INCLUDE)


# --- install helpers -------------------------------------------------------


def _find_one(root: Path, name: str) -> Path:
    matches = sorted(root.rglob(name))
    if not matches:
        sys.exit(f"error: {name} not produced under {root}")
    return matches[0]


def _install_lib(lib: Path, abi: str) -> None:
    lib_dir = DEPENDENCIES_DIR / "android" / abi / "lib"
    lib_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(lib, lib_dir / lib.name)
    log(f"{abi}: installed -> {lib_dir / lib.name}")


def _install_header(header: Path, dest_dir: Path) -> None:
    dest_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(header, dest_dir / header.name)
    log(f"header installed -> {dest_dir / header.name}")


def _install_header_tree(src_dir: Path, dest_dir: Path) -> None:
    """Install the C headers only.

    Deliberately not *.hpp: publicHeadersPath makes SwiftPM auto-generate an
    umbrella module over the whole directory, so a stray C++ header gets parsed
    as part of a C module build and dies on `'memory' file not found`. The
    Swift side uses shaderc's C API exclusively.
    """
    dest_dir.mkdir(parents=True, exist_ok=True)
    for header in sorted(src_dir.glob("*.h")):
        shutil.copy2(header, dest_dir / header.name)
    log(f"headers installed -> {dest_dir}")


# --- Entry point -----------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--abis", default="arm64-v8a,x86_64",
        help=f"comma-separated ABIs (choices: {','.join(ANDROID_ABIS)})",
    )
    parser.add_argument("--ndk", type=Path, default=None,
                        help="NDK path (else ANDROID_NDK_HOME / ANDROID_SDK_ROOT/ndk)")
    parser.add_argument("--api", type=int, default=ANDROID_API_DEFAULT,
                        help=f"Android API level (default: {ANDROID_API_DEFAULT})")
    parser.add_argument("--cmake", type=Path, default=None,
                        help="cmake path (else the SDK's bundled copy, else PATH)")
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK_DIR)
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--only", choices=("shaderc", "spirv-cross"), default=None,
                        help="build just one of the two")
    parser.add_argument("--clean", action="store_true",
                        help="wipe the work directory before building")
    args = parser.parse_args()


    abis = [a.strip() for a in args.abis.split(",") if a.strip()]
    unknown = [a for a in abis if a not in ANDROID_ABIS]
    if unknown:
        sys.exit(f"error: unknown ABI(s) {unknown}; choices: {', '.join(ANDROID_ABIS)}")

    work_dir: Path = args.work_dir.resolve()
    if args.clean and work_dir.exists():
        log(f"cleaning {work_dir}")
        shutil.rmtree(work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)

    cmake = find_cmake(args.cmake)
    ninja = find_ninja(cmake)
    ndk = find_ndk(args.ndk)
    log(f"using cmake {cmake}")
    log(f"using ninja {ninja}")
    log(f"using NDK {ndk} (API {args.api})")

    for abi in abis:
        if args.only in (None, "shaderc"):
            build_shaderc(cmake, ninja, work_dir, ndk, abi, args.api, args.jobs)
        if args.only in (None, "spirv-cross"):
            build_spirv_cross(cmake, ninja, work_dir, ndk, abi, args.api, args.jobs)

    log("done")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as exc:
        sys.exit(f"error: command failed with exit code {exc.returncode}")
