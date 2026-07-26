#!/usr/bin/env python3
"""Build wgpu-native for Apple platforms and package it as an XCFramework.

Produces Dependencies/wgpu_native.xcframework (the `CWgpu` binary target
referenced by Package.swift) with three slices:

  * macos-arm64_x86_64          (aarch64-apple-darwin + x86_64-apple-darwin)
  * ios-arm64                   (aarch64-apple-ios)
  * ios-arm64_x86_64-simulator  (aarch64-apple-ios-sim + x86_64-apple-ios)

Each slice wraps the **dynamic** libwgpu_native.dylib (install name
@rpath/libwgpu_native.dylib — wgpu-native's default). Shipping it dynamic,
under that exact name, keeps the whole process on ONE wgpu runtime: ThorVG's
framework already loads `@rpath/libwgpu_native.dylib`, so it resolves to the
same embedded copy the engine links here — a static slice would give each a
private copy and crossed handles would corrupt/crash.

The `webgpu`-native-specific Metal accessors the engine relies on
(wgpuTextureGetNativeMetalTexture / wgpuDeviceGetNativeMetalDevice /
wgpuQueueGetNativeMetalCommandQueue) are upstream as of v29.0.1.1 — no fork
patches are carried; we build the pinned tag straight from NucleantUI's fork.

The source is cloned into scripts/.work (shared with build_vulkan.py) so
repeated runs are incremental. Use --clean to start fresh.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

# --- Paths -----------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
PACKAGE_ROOT = SCRIPT_DIR.parent
DEPENDENCIES_DIR = PACKAGE_ROOT / "Dependencies"
DEFAULT_WORK_DIR = SCRIPT_DIR / ".work"

# --- Upstream source (NucleantUI's fork of gfx-rs/wgpu-native) -------------

WGPU_REPO = "https://github.com/NucleantUI/wgpu-native.git"
WGPU_REF = "v29.0.1.1"

DYLIB = "libwgpu_native.dylib"

# Apple deployment targets — must match Package.swift's platforms.
MACOS_DEPLOYMENT = "14.0"
IOS_DEPLOYMENT = "15.0"

# One xcframework slice per Apple platform. Each is lipo'd from its Rust
# target triples; `platform` is only used for logging/labels.
SLICES = {
    "macos": {
        "targets": ["aarch64-apple-darwin", "x86_64-apple-darwin"],
        "deployment_env": ("MACOSX_DEPLOYMENT_TARGET", MACOS_DEPLOYMENT),
    },
    "ios": {
        "targets": ["aarch64-apple-ios"],
        "deployment_env": ("IPHONEOS_DEPLOYMENT_TARGET", IOS_DEPLOYMENT),
    },
    "iossim": {
        "targets": ["aarch64-apple-ios-sim", "x86_64-apple-ios"],
        "deployment_env": ("IPHONEOS_DEPLOYMENT_TARGET", IOS_DEPLOYMENT),
    },
}

ALL_TARGETS = sorted({t for s in SLICES.values() for t in s["targets"]})


# --- Shell helpers ---------------------------------------------------------

def log(message: str) -> None:
    print(f"\033[1;34m[build_wgpu]\033[0m {message}", flush=True)


def run(cmd: list[str], cwd: Path | None = None, env: dict | None = None) -> None:
    log("$ " + " ".join(str(c) for c in cmd) + (f"   (cwd={cwd})" if cwd else ""))
    subprocess.run(cmd, cwd=cwd, env=env, check=True)


def require(tool: str) -> None:
    if shutil.which(tool) is None:
        sys.exit(f"error: required tool '{tool}' not found on PATH")


def sync_repo(repo: str, ref: str, dest: Path) -> None:
    """Clone `repo` at `ref` (with submodules) into `dest`, or update it."""
    require("git")
    if (dest / ".git").is_dir():
        log(f"updating {dest.name} -> {ref}")
        run(["git", "fetch", "--tags", "--depth", "1", "origin", ref], cwd=dest)
        run(["git", "checkout", "--force", ref], cwd=dest)
    else:
        dest.parent.mkdir(parents=True, exist_ok=True)
        log(f"cloning {repo} @ {ref}")
        run(["git", "clone", "--depth", "1", "--branch", ref,
             "--recurse-submodules", repo, str(dest)])
    if (dest / ".gitmodules").is_file():
        run(["git", "submodule", "update", "--init", "--depth", "1"], cwd=dest)


# --- Rust build ------------------------------------------------------------

def ensure_targets(src: Path) -> None:
    """Install the Rust std for every triple onto the repo-pinned toolchain."""
    require("rustup")
    # Run inside the repo so wgpu-native's rust-toolchain.toml override selects
    # the toolchain the std is added to — otherwise it lands on the default
    # toolchain and the pinned one still can't cross-compile.
    run(["rustup", "target", "add", *ALL_TARGETS], cwd=src)


def cargo_build(src: Path, target: str, deployment_env: tuple[str, str]) -> Path:
    """Release-build wgpu-native for one triple; return the built dylib path."""
    require("cargo")
    env = dict(os.environ)
    # Force the rustup shims ahead of any standalone /usr/local/bin rust — the
    # latter ignores the repo's rust-toolchain.toml and only carries the host
    # target's std, so cross builds fail with "can't find crate for core".
    cargo_bin = Path.home() / ".cargo" / "bin"
    env["PATH"] = str(cargo_bin) + os.pathsep + env.get("PATH", "")
    key, value = deployment_env
    env[key] = value
    run(["cargo", "build", "--release", "--target", target], cwd=src, env=env)
    dylib = src / "target" / target / "release" / DYLIB
    if not dylib.is_file():
        sys.exit(f"error: expected dylib not produced: {dylib}")
    return dylib


def lipo(dylibs: list[Path], out: Path) -> Path:
    """Fuse per-arch dylibs into one fat dylib (or copy through if single), and
    stamp the install name to @rpath/libwgpu_native.dylib — cargo emits an
    absolute build-dir install name, but the whole sharing model (ThorVG's
    framework loads `@rpath/libwgpu_native.dylib`, the engine links the same)
    depends on this exact id."""
    require("lipo")
    require("install_name_tool")
    out.parent.mkdir(parents=True, exist_ok=True)
    if len(dylibs) == 1:
        shutil.copy2(dylibs[0], out)
    else:
        run(["lipo", "-create", *[str(d) for d in dylibs], "-output", str(out)])
    run(["install_name_tool", "-id", f"@rpath/{DYLIB}", str(out)])
    return out


# --- Header module ---------------------------------------------------------

def assemble_headers(src: Path, out_dir: Path) -> Path:
    """Lay out the CWgpu clang module: wgpu.h + webgpu.h (flat, since wgpu.h
    does `#include "webgpu.h"`) plus a modulemap named to match the existing
    `import CWgpu` — so no Swift import churn."""
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True)
    shutil.copy2(src / "ffi" / "wgpu.h", out_dir / "wgpu.h")
    shutil.copy2(src / "ffi" / "webgpu-headers" / "webgpu.h", out_dir / "webgpu.h")
    (out_dir / "module.modulemap").write_text(
        "// wgpu-native C API, exposed to Swift as `CWgpu` (module name kept so\n"
        "// `import CWgpu` in VulkanRenderEngine/WgpuContext is unchanged).\n"
        "module CWgpu {\n"
        '    header "wgpu.h"\n'
        "    export *\n"
        "}\n"
    )
    return out_dir


# --- XCFramework -----------------------------------------------------------

def create_xcframework(slice_libs: dict[str, Path], headers: Path, out: Path) -> None:
    require("xcodebuild")
    if out.exists():
        log(f"removing previous {out}")
        shutil.rmtree(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["xcodebuild", "-create-xcframework"]
    for lib in slice_libs.values():
        cmd += ["-library", str(lib), "-headers", str(headers)]
    cmd += ["-output", str(out)]
    run(cmd)
    log(f"wgpu_native.xcframework installed -> {out}")


def create_ios_framework_xcframework(ios_dylib: Path, iossim_dylib: Path,
                                     src: Path, out: Path) -> None:
    """iOS links `.framework` bundles, not bare dylibs — so alongside the
    library xcframework (used on macOS) emit a framework-style one for iOS:
    wgpu_native.framework per slice, install name
    @rpath/wgpu_native.framework/wgpu_native (the same reference ThorVG's iOS
    framework links, so the process shares one embedded copy). Carries a module
    map so Swift can `import wgpu_native`."""
    require("xcodebuild")
    require("install_name_tool")
    if out.exists():
        shutil.rmtree(out)
    stage = out.parent / "_wgpu_fw_stage"
    if stage.exists():
        shutil.rmtree(stage)

    plist = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict>\n'
        '  <key>CFBundleExecutable</key><string>wgpu_native</string>\n'
        '  <key>CFBundleIdentifier</key><string>org.gfx-rs.wgpu-native</string>\n'
        '  <key>CFBundleName</key><string>wgpu_native</string>\n'
        '  <key>CFBundlePackageType</key><string>FMWK</string>\n'
        '  <key>MinimumOSVersion</key><string>15.0</string>\n'
        '</dict></plist>\n'
    )

    def _framework(dylib: Path, slice_name: str) -> Path:
        fw = stage / slice_name / "wgpu_native.framework"
        (fw / "Headers").mkdir(parents=True)
        (fw / "Modules").mkdir(parents=True)
        shutil.copy2(dylib, fw / "wgpu_native")
        run(["install_name_tool", "-id",
             "@rpath/wgpu_native.framework/wgpu_native", str(fw / "wgpu_native")])
        shutil.copy2(src / "ffi" / "wgpu.h", fw / "Headers" / "wgpu.h")
        shutil.copy2(src / "ffi" / "webgpu-headers" / "webgpu.h", fw / "Headers" / "webgpu.h")
        (fw / "Modules" / "module.modulemap").write_text(
            "framework module wgpu_native {\n"
            '    header "wgpu.h"\n'
            "    export *\n"
            "}\n"
        )
        (fw / "Info.plist").write_text(plist)
        return fw

    ios_fw = _framework(ios_dylib, "ios")
    sim_fw = _framework(iossim_dylib, "iossim")
    out.parent.mkdir(parents=True, exist_ok=True)
    run(["xcodebuild", "-create-xcframework",
         "-framework", str(ios_fw), "-framework", str(sim_fw),
         "-output", str(out)])
    shutil.rmtree(stage, ignore_errors=True)
    log(f"wgpu_native_framework.xcframework installed -> {out}")


# --- Entry point -----------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ref", default=WGPU_REF, help="git tag/branch to build")
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK_DIR)
    parser.add_argument("--clean", action="store_true",
                        help="wipe the work directory before building")
    args = parser.parse_args()

    if sys.platform != "darwin":
        sys.exit("error: build_wgpu.py targets Apple platforms; run on macOS")

    work_dir: Path = args.work_dir.resolve()
    if args.clean and work_dir.exists():
        log(f"cleaning {work_dir}")
        shutil.rmtree(work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)

    src = work_dir / "wgpu-native"
    sync_repo(WGPU_REPO, args.ref, src)
    ensure_targets(src)

    # Build every triple once, then fuse into per-platform slices.
    built: dict[str, Path] = {t: cargo_build(src, t, _env_for(t)) for t in ALL_TARGETS}

    stage = work_dir / "stage"
    slice_libs: dict[str, Path] = {}
    for name, spec in SLICES.items():
        fused = lipo([built[t] for t in spec["targets"]], stage / name / DYLIB)
        slice_libs[name] = fused

    headers = assemble_headers(src, stage / "Headers")
    create_xcframework(slice_libs, headers, DEPENDENCIES_DIR / "wgpu_native.xcframework")

    # iOS also gets a framework-style xcframework (iOS links frameworks, not
    # bare dylibs); macOS keeps using the library one above.
    create_ios_framework_xcframework(
        slice_libs["ios"], slice_libs["iossim"], src,
        DEPENDENCIES_DIR / "wgpu_native_framework.xcframework")

    log("done")
    return 0


def _env_for(target: str) -> tuple[str, str]:
    for spec in SLICES.values():
        if target in spec["targets"]:
            return spec["deployment_env"]
    return ("MACOSX_DEPLOYMENT_TARGET", MACOS_DEPLOYMENT)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as exc:
        sys.exit(f"error: command failed with exit code {exc.returncode}")
    except KeyboardInterrupt:
        sys.exit(130)
