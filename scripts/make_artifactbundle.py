#!/usr/bin/env python3
"""Package one of a platform's prebuilt libraries as a SwiftPM artifact
bundle, named after the library, the platform and the architecture:

    <output>/<name>.artifactbundle.zip      e.g. wgpu_native-linux-x86_64
        <name>.artifactbundle/
            info.json            one "staticLibrary" artifact
            lib/lib<lib>.so|.a   the library

for a `.binaryTarget(..., url:/path:)` on Linux, Android and WebAssembly, the
way each library is its own xcframework zip on Apple's platforms. One bundle
per library, platform and architecture, so a package downloads only what it
builds with, and each archive says what it holds.

Shared libraries stay shared. SwiftPM takes a bundle's library as it is: it
copies the file next to the product it builds and links it with -l<name>, so
a .so in the bundle is linked dynamically and loaded from beside the
executable ($ORIGIN) — one libwgpu_native.so in the process, which ThorVG's
libthorvg-1.so links too, and the same file any other package or Python wheel
can link. (The artifact type is still "staticLibrary": SwiftPM has no other
for a library on these platforms.)

Several archives given for one library (spirv-cross's) are merged into one,
since an artifact is one file.

    python3 scripts/make_artifactbundle.py --triple x86_64-unknown-linux-gnu \\
        --library Dependencies/linux/lib/libwgpu_native.so \\
        --name wgpu_native-linux-x86_64 --output dist

`--library libspirv-cross.a=a.a,b.a` names a merged archive; --ar (an
MRI-capable archiver: llvm-ar, GNU ar) does the merging. The C targets carry
their own headers, so the bundle has none.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def log(message: str) -> None:
    print(f"[make_artifactbundle] {message}", flush=True)


def merge_archives(ar: str, archives: list[Path], output: Path) -> None:
    script = [f"CREATE {output}", *(f"ADDLIB {a}" for a in archives), "SAVE", "END"]
    subprocess.run([ar, "-M"], input="\n".join(script) + "\n", text=True, check=True)
    subprocess.run([ar, "s", str(output)], check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--library", action="append", required=True,
                        help="a library file, or <libname>=<archive>,<archive>,... to merge")
    parser.add_argument("--triple", action="append", required=True, help="a target triple the libraries are for")
    parser.add_argument("--name", required=True, help="file name of the zip, without .artifactbundle.zip")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", default="1.0.0")
    parser.add_argument("--ar", default=shutil.which("llvm-ar") or "ar")
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temp:
        bundle = Path(temp) / f"{args.name}.artifactbundle"
        lib_dir = bundle / "lib"
        lib_dir.mkdir(parents=True)
        artifacts = {}
        for spec in args.library:
            if "=" in spec:
                name, sources = spec.split("=", 1)
                archives = [Path(s).resolve() for s in sources.split(",")]
                log(f"merging {len(archives)} archives -> {name}")
                merge_archives(args.ar, archives, (lib_dir / name).resolve())
            else:
                source = Path(spec)
                if not source.is_file():
                    sys.exit(f"error: no library {source}")
                name = source.name
                shutil.copy2(source, lib_dir / name)
            if not name.startswith("lib"):
                sys.exit(f"error: {name}: SwiftPM links a bundle's library as -l<name>, so it must start with lib")
            artifact = name.split(".", 1)[0][3:]
            artifacts[artifact] = {
                "type": "staticLibrary",
                "version": args.version,
                "variants": [{"path": f"lib/{name}", "supportedTriples": args.triple}],
            }
            log(f"{artifact}: lib/{name}")
        (bundle / "info.json").write_text(json.dumps({"schemaVersion": "1.0", "artifacts": artifacts}, indent=2) + "\n")
        zip_path = args.output / f"{args.name}.artifactbundle.zip"
        zip_path.unlink(missing_ok=True)
        shutil.make_archive(str(zip_path.with_suffix("")), "zip", root_dir=temp, base_dir=bundle.name)
    log(f"wrote {zip_path} ({zip_path.stat().st_size // (1024 * 1024)} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
