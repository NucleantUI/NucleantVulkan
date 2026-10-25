#!/usr/bin/env python3
"""Build the Vulkan library and copy it into the package.

  * macOS  -> builds MoltenVK and produces MoltenVK.xcframework, copied to
              Dependencies/MoltenVK.xcframework (the binary target referenced
              by Package.swift).
  * Linux  -> builds the Khronos Vulkan-Loader and produces libvulkan.so*,
              copied to Dependencies/linux/lib.
  * Windows -> builds the same loader as vulkan-1.dll with its import library,
              copied to Dependencies/windows/{bin,lib}. Native on Windows;
              elsewhere cross-compiled (--windows, scripts/windows-cross/).

The sources are cloned into a scratch work directory (scripts/.work by
default) so repeated runs are incremental. Use --clean to start fresh.
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

# The two forms of MoltenVK, mirroring wgpu_native.xcframework /
# wgpu_native_framework.xcframework: PIP_MODE links the bare dylib so the wheel
# vendors a plain file into nucleant/.dylibs, Xcode embed mode links the
# framework. Package.swift resolves both under Dependencies/macos/.
MOLTENVK_XCFW = DEPENDENCIES_DIR / "macos" / "MoltenVK.xcframework"
MOLTENVK_LIB_XCFW = DEPENDENCIES_DIR / "macos" / "MoltenVK_lib.xcframework"
MOLTENVK_DYLIB = "libMoltenVK.dylib"

# --- Upstream sources ------------------------------------------------------

MOLTENVK_REPO = "https://github.com/KhronosGroup/MoltenVK.git"
MOLTENVK_REF = "v1.2.11"

VULKAN_LOADER_REPO = "https://github.com/KhronosGroup/Vulkan-Loader.git"
# The loader the release's Linux artifact bundle ships, at the version of the
# Vulkan headers every platform compiles against (Sources/CVulkan,
# Sources/CVulkanLinuxPrebuilt: Vulkan-Headers 1.4.334).
VULKAN_LOADER_REF = "v1.4.334"

# Apple platforms we package into the xcframework. Each entry maps a
# fetchDependencies flag to its corresponding `make` target. macOS and iOS
# (iPadOS) only, for now: nothing above NucleantVulkan (Skia, ThorVG) is built
# for tvOS or visionOS yet.
MOLTENVK_PLATFORMS = {
    "--macos": "macos",
    "--ios": "ios",
    "--iossim": "iossim",
}


# --- Shell helpers ---------------------------------------------------------

def log(message: str) -> None:
    print(f"\033[1;34m[build_vulkan]\033[0m {message}", flush=True)


def run(cmd: list[str], cwd: Path | None = None, env: dict | None = None) -> None:
    log("$ " + " ".join(str(c) for c in cmd) + (f"   (cwd={cwd})" if cwd else ""))
    subprocess.run(cmd, cwd=cwd, env=env, check=True)


def require(tool: str) -> None:
    if shutil.which(tool) is None:
        sys.exit(f"error: required tool '{tool}' not found on PATH")


def sync_repo(repo: str, ref: str, dest: Path) -> None:
    """Clone `repo` at `ref` into `dest`, or update it if already present."""
    require("git")
    if (dest / ".git").is_dir():
        log(f"updating {dest.name} -> {ref}")
        run(["git", "fetch", "--tags", "--depth", "1", "origin", ref], cwd=dest)
        run(["git", "checkout", "--force", ref], cwd=dest)
    else:
        dest.parent.mkdir(parents=True, exist_ok=True)
        log(f"cloning {repo} @ {ref}")
        run(["git", "clone", "--depth", "1", "--branch", ref, repo, str(dest)])
    # Pull in submodules where present (Vulkan-Loader pins its deps this way).
    if (dest / ".gitmodules").is_file():
        run(["git", "submodule", "update", "--init", "--depth", "1"], cwd=dest)


def replace_tree(src: Path, dst: Path) -> None:
    """Atomically-ish replace directory `dst` with `src` (a copy)."""
    if not src.exists():
        sys.exit(f"error: expected build artifact not found: {src}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        log(f"removing previous {dst}")
        shutil.rmtree(dst)
    log(f"copying {src} -> {dst}")
    shutil.copytree(src, dst, symlinks=True)


# --- macOS: MoltenVK -------------------------------------------------------

def _library_xcframework_plist(slices: list[tuple[str, str, list[str]]]) -> str:
    """Info.plist for an xcframework holding bare dylibs rather than frameworks.

    Each slice is (identifier, library filename, architectures). No HeadersPath
    key: CVulkan carries its own Vulkan headers, so the binary target is only
    ever used for linking.
    """
    entries = []
    for identifier, library, arches in slices:
        archs = "".join(f"\n\t\t\t\t<string>{a}</string>" for a in arches)
        entries.append(f"""\t\t<dict>
\t\t\t<key>BinaryPath</key>
\t\t\t<string>{library}</string>
\t\t\t<key>LibraryIdentifier</key>
\t\t\t<string>{identifier}</string>
\t\t\t<key>LibraryPath</key>
\t\t\t<string>{library}</string>
\t\t\t<key>SupportedArchitectures</key>
\t\t\t<array>{archs}
\t\t\t</array>
\t\t\t<key>SupportedPlatform</key>
\t\t\t<string>macos</string>
\t\t</dict>""")
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n'
        "<dict>\n"
        "\t<key>AvailableLibraries</key>\n"
        "\t<array>\n" + "\n".join(entries) + "\n\t</array>\n"
        "\t<key>CFBundlePackageType</key>\n"
        "\t<string>XFWK</string>\n"
        "\t<key>XCFrameworkFormatVersion</key>\n"
        "\t<string>1.0</string>\n"
        "</dict>\n"
        "</plist>\n"
    )


def _extract_framework_binary(framework: Path, dest: Path, install_name: str) -> list[str]:
    """Copy a framework's Mach-O out as a standalone dylib.

    The binary is byte-identical apart from its LC_ID_DYLIB — retargeting it
    from `@rpath/Foo.framework/Foo` to `@rpath/libfoo.dylib` is what lets
    consumers link the loose form. `install_name_tool` invalidates the code
    signature, and an arm64 slice will not load unsigned, so the copy is
    re-signed ad-hoc.
    """
    binary = framework / "Versions" / "A" / framework.stem
    if not binary.is_file():
        binary = framework / framework.stem  # shallow bundle (iOS-style layout)
    if not binary.is_file():
        sys.exit(f"error: no Mach-O found in {framework}")

    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, dest)
    run(["install_name_tool", "-id", install_name, str(dest)])
    run(["codesign", "--force", "--sign", "-", str(dest)])

    arches = subprocess.check_output(["lipo", "-archs", str(dest)], text=True)
    return arches.split()


def install_moltenvk_lib_xcframework() -> None:
    """Derive MoltenVK_lib.xcframework from the framework xcframework."""
    require("install_name_tool")
    slices = sorted(MOLTENVK_XCFW.glob("macos-*"))
    if not slices:
        sys.exit(f"error: no macos slice in {MOLTENVK_XCFW}")

    if MOLTENVK_LIB_XCFW.exists():
        shutil.rmtree(MOLTENVK_LIB_XCFW)

    entries = []
    for slice_dir in slices:
        dylib = MOLTENVK_LIB_XCFW / slice_dir.name / MOLTENVK_DYLIB
        arches = _extract_framework_binary(
            slice_dir / "MoltenVK.framework", dylib, f"@rpath/{MOLTENVK_DYLIB}"
        )
        entries.append((slice_dir.name, MOLTENVK_DYLIB, arches))
        log(f"extracted {dylib.relative_to(PACKAGE_ROOT)} ({' '.join(arches)})")

    (MOLTENVK_LIB_XCFW / "Info.plist").write_text(_library_xcframework_plist(entries))
    log("MoltenVK_lib.xcframework installed")


def build_moltenvk(work_dir: Path, ref: str, jobs: int) -> None:
    require("xcodebuild")
    src = work_dir / "MoltenVK"
    sync_repo(MOLTENVK_REPO, ref, src)

    # fetchDependencies builds SPIRV-Cross / glslang / etc. for each platform.
    log("fetching MoltenVK dependencies (this is slow on a cold checkout)")
    run(["./fetchDependencies", *MOLTENVK_PLATFORMS.keys()], cwd=src)

    # Build every platform slice; MoltenVK assembles the xcframework for us.
    # One platform after another, not make -j: each target is an xcodebuild
    # of the same project, and parallel ones lock each other's build database
    # ("database is locked"). xcodebuild compiles in parallel by itself.
    run(["make", *MOLTENVK_PLATFORMS.values()], cwd=src)
    install_moltenvk(src)


def install_moltenvk(src: Path) -> None:
    """The built MoltenVK.xcframework into Dependencies/macos, and
    MoltenVK_lib.xcframework derived from it."""
    # Prefer the dynamic framework variant (matches the bundled layout: a
    # MoltenVK.framework holding a dylib). Fall back to whatever was emitted.
    candidates = [
        src / "Package" / "Latest" / "MoltenVK" / "dynamic" / "MoltenVK.xcframework",
        src / "Package" / "Release" / "MoltenVK" / "dynamic" / "MoltenVK.xcframework",
        src / "Package" / "Latest" / "MoltenVK" / "MoltenVK.xcframework",
        src / "Package" / "Release" / "MoltenVK" / "MoltenVK.xcframework",
    ]
    xcframework = next((c for c in candidates if c.exists()), None)
    if xcframework is None:
        sys.exit("error: could not locate built MoltenVK.xcframework under Package/")

    replace_tree(xcframework, MOLTENVK_XCFW)
    log("MoltenVK.xcframework installed")
    install_moltenvk_lib_xcframework()


# One platform at a time, in two phases, then --install-only:
#
#   --dependencies <platform>   fetchDependencies for it (SPIRV-Cross,
#                               glslang, ... for that platform)
#   --platform <platform>       make for it
#
# All the --dependencies first: fetchDependencies ends with `make clean` of
# MoltenVK, which would drop the platforms already made. --keep-cache keeps
# its own intermediates, where the platforms built before stay staged, so its
# libraries' xcframeworks grow by one platform each run; each make then adds
# its platform to MoltenVK.xcframework the same way. (The flag, not
# KEEP_CACHE in the environment: fetchDependencies resets that variable.)

def build_moltenvk_dependencies(work_dir: Path, ref: str, platform_flag: str) -> None:
    require("xcodebuild")
    src = work_dir / "MoltenVK"
    sync_repo(MOLTENVK_REPO, ref, src)
    run(["./fetchDependencies", "--keep-cache", platform_flag], cwd=src)


def build_moltenvk_platform(work_dir: Path, platform_flag: str) -> None:
    require("xcodebuild")
    run(["make", MOLTENVK_PLATFORMS[platform_flag]], cwd=work_dir / "MoltenVK")


# --- Linux: Vulkan-Loader --------------------------------------------------

def build_vulkan_loader(work_dir: Path, ref: str, jobs: int) -> None:
    require("cmake")
    src = work_dir / "Vulkan-Loader"
    sync_repo(VULKAN_LOADER_REPO, ref, src)

    build = src / "build"
    # UPDATE_DEPS fetches and builds the matching Vulkan-Headers automatically.
    run([
        "cmake", "-S", str(src), "-B", str(build),
        "-D", "UPDATE_DEPS=ON",
        "-D", "CMAKE_BUILD_TYPE=Release",
        "-D", "BUILD_TESTS=OFF",
    ])
    run(["cmake", "--build", str(build), "--config", "Release", f"-j{jobs}"])

    loader = build / "loader" / "libvulkan.so"
    if not loader.exists():
        sys.exit(f"error: no libvulkan.so produced under {loader.parent}")

    # One file, libvulkan.so, made relocatable: SONAME its own name, so an
    # executable linked with it (-lvulkan) needs exactly the file SwiftPM
    # copies next to it from the release's artifact bundle, and RUNPATH
    # $ORIGIN. The driver (ICD) is still the machine's: the loader finds it
    # through the usual icd.d manifests.
    require("patchelf")
    dest_dir = DEPENDENCIES_DIR / "linux" / "lib"
    dest_dir.mkdir(parents=True, exist_ok=True)
    for old in dest_dir.glob("libvulkan.so*"):
        old.unlink()
    target = dest_dir / "libvulkan.so"
    shutil.copy2(loader.resolve(), target)
    run(["patchelf", "--set-soname", "libvulkan.so", str(target)])
    run(["patchelf", "--set-rpath", "$ORIGIN", str(target)])
    log(f"installed {target.relative_to(PACKAGE_ROOT)}")


# --- Windows: Vulkan-Loader ------------------------------------------------
#
# vulkan-1.dll for the release's Windows artifact bundle, from the same tag as
# Linux's libvulkan.so:
#
#   Dependencies/windows/bin/vulkan-1.dll
#   Dependencies/windows/lib/vulkan-1.lib    the DLL's import library
#
# The app ships it beside its executable, the first place Windows looks for a
# DLL; the driver (ICD) is still the machine's, found through the registry.
#
# Native on Windows with CMake's Visual Studio generator, which finds MSVC by
# itself (no Developer Prompt, and never a MinGW gcc that happens to be on
# PATH). Elsewhere Ninja, with whatever toolchain CMAKE_TOOLCHAIN_FILE names —
# scripts/windows-cross/toolchain.cmake in that image.

# --windows-arch -> the Visual Studio generator's platform.
WINDOWS_PLATFORMS = {"x86_64": "x64", "arm64": "ARM64"}


def default_windows_arch() -> str:
    """The host's architecture on Windows (the build is native there); x86_64
    for a cross-compile."""
    if platform.system() == "Windows" and platform.machine().upper() == "ARM64":
        return "arm64"
    return "x86_64"


def build_vulkan_loader_windows(work_dir: Path, ref: str, jobs: int, arch: str) -> None:
    require("cmake")
    src = work_dir / "Vulkan-Loader"
    sync_repo(VULKAN_LOADER_REPO, ref, src)

    build = src / f"build-windows-{arch}"
    configure = [
        "cmake", "-S", str(src), "-B", str(build),
        "-D", "UPDATE_DEPS=ON",
        "-D", "CMAKE_BUILD_TYPE=Release",
        "-D", "BUILD_TESTS=OFF",
    ]
    if platform.system() == "Windows":
        configure += ["-A", WINDOWS_PLATFORMS[arch]]
    else:
        require("ninja")
        configure += ["-G", "Ninja"]
    run(configure)
    run(["cmake", "--build", str(build), "--config", "Release", f"-j{jobs}"])

    # loader/ under Ninja, loader/Release/ under Visual Studio.
    dll = next(iter(sorted((build / "loader").rglob("vulkan-1.dll"))), None)
    implib = next(iter(sorted((build / "loader").rglob("vulkan-1.lib"))), None)
    if dll is None or implib is None:
        sys.exit(f"error: no vulkan-1.dll / vulkan-1.lib produced under {build / 'loader'}")

    dest = DEPENDENCIES_DIR / "windows"
    (dest / "bin").mkdir(parents=True, exist_ok=True)
    (dest / "lib").mkdir(parents=True, exist_ok=True)
    shutil.copy2(dll, dest / "bin" / "vulkan-1.dll")
    shutil.copy2(implib, dest / "lib" / "vulkan-1.lib")
    log(f"installed {(dest / 'bin' / 'vulkan-1.dll').relative_to(PACKAGE_ROOT)}")
    log(f"installed {(dest / 'lib' / 'vulkan-1.lib').relative_to(PACKAGE_ROOT)}")


# --- Entry point -----------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ref", default=None,
                        help="git tag/branch to build (defaults per platform)")
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK_DIR,
                        help=f"scratch directory for sources (default: {DEFAULT_WORK_DIR})")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4,
                        help="parallel build jobs")
    parser.add_argument("--clean", action="store_true",
                        help="wipe the work directory before building")
    parser.add_argument("--repackage-only", action="store_true",
                        help="re-derive MoltenVK_lib.xcframework from the already "
                             "installed MoltenVK.xcframework, without rebuilding")
    platforms = [f.lstrip("-") for f in MOLTENVK_PLATFORMS]
    parser.add_argument("--dependencies", choices=platforms, default=None,
                        help="macOS only: build MoltenVK's dependencies for just this platform "
                             "(all of these before any --platform)")
    parser.add_argument("--platform", choices=platforms, default=None,
                        help="macOS only: build MoltenVK for just this platform, without installing")
    parser.add_argument("--install-only", action="store_true",
                        help="macOS only: install the MoltenVK.xcframework the --platform runs built")
    parser.add_argument("--windows", action="store_true",
                        help="build the Windows loader (native on Windows, else cross-compiled "
                             "through CMAKE_TOOLCHAIN_FILE)")
    parser.add_argument("--windows-arch", choices=list(WINDOWS_PLATFORMS), default=None,
                        help="Windows only: architecture (default: the host's on Windows, "
                             "else x86_64)")
    args = parser.parse_args()

    if args.repackage_only:
        install_moltenvk_lib_xcframework()
        log("done")
        return 0

    work_dir: Path = args.work_dir.resolve()
    if args.clean and work_dir.exists():
        log(f"cleaning {work_dir}")
        shutil.rmtree(work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)

    system = platform.system()
    if args.windows or system == "Windows":
        build_vulkan_loader_windows(work_dir, args.ref or VULKAN_LOADER_REF, args.jobs,
                                    args.windows_arch or default_windows_arch())
    elif system == "Darwin" and args.dependencies:
        build_moltenvk_dependencies(work_dir, args.ref or MOLTENVK_REF, f"--{args.dependencies}")
    elif system == "Darwin" and args.platform:
        build_moltenvk_platform(work_dir, f"--{args.platform}")
    elif system == "Darwin" and args.install_only:
        install_moltenvk(work_dir / "MoltenVK")
    elif system == "Darwin":
        build_moltenvk(work_dir, args.ref or MOLTENVK_REF, args.jobs)
    elif system == "Linux":
        build_vulkan_loader(work_dir, args.ref or VULKAN_LOADER_REF, args.jobs)
    else:
        sys.exit(f"error: unsupported platform '{system}' (need Darwin, Linux or Windows)")

    log("done")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as exc:
        sys.exit(f"error: command failed with exit code {exc.returncode}")
    except KeyboardInterrupt:
        sys.exit(130)
