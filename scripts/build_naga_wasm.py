#!/usr/bin/env python3
"""Build NagaWebGPU (SPIR-V -> WGSL for the wasm Vulkan implementation).

The browser's WebGPU only accepts WGSL, while everything the engine hands
vkCreate*Pipelines is SPIR-V. Web/nucleant-webgpu.js runs each pipeline's
SPIR-V through this module (naga, plus the rewrites for what Vulkan has and
WebGPU lacks — see NagaWebGPU/src/lib.rs) when the pipeline is created.

Output: Web/naga_webgpu.wasm, served next to nucleant-webgpu.js.

Needs Rust with the wasm32-unknown-unknown target
(`rustup target add wasm32-unknown-unknown`). wasm-opt is used when on PATH.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

PACKAGE_ROOT = Path(__file__).resolve().parent.parent
CRATE = PACKAGE_ROOT / "NagaWebGPU"
BUILT = CRATE / "target" / "wasm32-unknown-unknown" / "release" / "naga_webgpu.wasm"
OUTPUT = PACKAGE_ROOT / "Web" / "naga_webgpu.wasm"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--no-opt", action="store_true", help="skip wasm-opt")
    args = parser.parse_args(argv)

    cargo_home_bin = Path.home() / ".cargo" / "bin"
    env = dict(os.environ)
    # rustup's cargo must see rustup's rustc, not a distro one without the wasm target.
    env["PATH"] = os.pathsep.join([str(cargo_home_bin), env.get("PATH", "")])
    cargo = shutil.which("cargo", path=env["PATH"])
    if cargo is None:
        sys.exit("error: cargo not found; install Rust from https://rustup.rs")
    command = [cargo, "build", "--release", "--target", "wasm32-unknown-unknown"]
    print("+", " ".join(command), flush=True)
    if subprocess.run(command, cwd=CRATE, env=env).returncode != 0:
        sys.exit("error: cargo build failed (rustup target add wasm32-unknown-unknown?)")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    wasm_opt = None if args.no_opt else shutil.which("wasm-opt")
    if wasm_opt:
        command = [wasm_opt, "-Oz", "--strip-debug", "--strip-producers", "--enable-bulk-memory",
                   "--enable-sign-ext", "--enable-nontrapping-float-to-int", "--enable-mutable-globals",
                   str(BUILT), "-o", str(OUTPUT)]
        print("+", " ".join(command), flush=True)
        if subprocess.run(command).returncode != 0:
            sys.exit("error: wasm-opt failed")
    else:
        shutil.copy2(BUILT, OUTPUT)
    print(f"wrote {OUTPUT} ({OUTPUT.stat().st_size / 1e6:.2f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
