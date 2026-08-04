#!/usr/bin/env python3
"""Build the Vulkan library and copy it into the package.

  * macOS  -> builds MoltenVK and produces MoltenVK.xcframework, copied to
              Dependencies/MoltenVK.xcframework (the binary target referenced
              by Package.swift).
  * Linux  -> builds the Khronos Vulkan-Loader and produces libvulkan.so*,
              copied to Dependencies/linux/lib.

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
VULKAN_LOADER_REF = "v1.4.309"

# Apple platforms we package into the xcframework. Each entry maps a
# fetchDependencies flag to its corresponding `make` target.
MOLTENVK_PLATFORMS = {
    "--macos": "macos",
    "--ios": "ios",
    "--iossim": "iossim",
    "--tvos": "tvos",
    "--tvossim": "tvossim",
    "--visionos": "visionos",
    "--visionossim": "visionossim",
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
    run(["make", *MOLTENVK_PLATFORMS.values(), f"-j{jobs}"], cwd=src)

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

    loader_dir = build / "loader"
    libs = sorted(loader_dir.glob("libvulkan.so*"))
    if not libs:
        sys.exit(f"error: no libvulkan.so produced under {loader_dir}")

    dest_dir = DEPENDENCIES_DIR / "linux" / "lib"
    dest_dir.mkdir(parents=True, exist_ok=True)
    for lib in libs:
        target = dest_dir / lib.name
        if target.exists() or target.is_symlink():
            target.unlink()
        if lib.is_symlink():
            os.symlink(os.readlink(lib), target)
        else:
            shutil.copy2(lib, target)
        log(f"installed {target.relative_to(PACKAGE_ROOT)}")
    log("libvulkan installed")


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
    if system == "Darwin":
        build_moltenvk(work_dir, args.ref or MOLTENVK_REF, args.jobs)
    elif system == "Linux":
        build_vulkan_loader(work_dir, args.ref or VULKAN_LOADER_REF, args.jobs)
    else:
        sys.exit(f"error: unsupported platform '{system}' (need Darwin or Linux)")

    log("done")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as exc:
        sys.exit(f"error: command failed with exit code {exc.returncode}")
    except KeyboardInterrupt:
        sys.exit(130)
