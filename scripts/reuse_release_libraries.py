#!/usr/bin/env python3
"""Take a platform's archives from the last release when nothing they are
built from has changed since, instead of building them again.

Every platform's libraries are built from source by build-deps.yml, which
takes most of an hour. They only change when what they are built from
changes: the build scripts (which pin each dependency's tag and set its
build options), the NDK for Android, the Swift toolchain whose clang builds
the wasm libraries. So each release records a fingerprint of those inputs per
platform, in its `deps.json` asset, and the next build of a platform whose
fingerprint is unchanged downloads that release's archives instead:

    fetch <platform> --version X --output dist
                                the last release's archives for the platform,
                                into dist/, if its fingerprint is unchanged
                                and it has them all; writes reused=true|false
                                to $GITHUB_OUTPUT
    record <platform> --output dist
                                dist/fingerprint-<platform>.txt, uploaded with
                                the archives — written by the job that built
                                (or reused) them, in its own environment
    collect dist                print deps.json from those files, for the
                                release to publish
    fingerprint <platform>      print the platform's fingerprint

A reused artifact bundle gets the new version in its info.json, so it is the
archive this release would have built, down to the version it reports; an
xcframework zip has no version and is reused as it is.

What the fingerprints cannot see is how build-deps.yml calls the scripts
(their arguments, the runners). After changing that, bump DEPS_REVISION there,
or run with `rebuild`.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import sys
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent

LIBRARY_SCRIPTS = ["build_wgpu.py", "build_vulkan.py", "build_shader_tools.py", "make_artifactbundle.py"]


def _bundles(libraries: list[str], suffix: str) -> list[str]:
    return [f"{library}-{suffix}.artifactbundle.zip" for library in libraries]


# Each platform build-deps.yml builds: the scripts its libraries are built
# with, the environment variables that also decide them, and the archives
# it makes (the names release.yml publishes).
PLATFORMS: dict[str, dict] = {
    "apple": {
        "scripts": ["build_wgpu.py", "build_vulkan.py", "build_shader_tools.py"],
        "env": [],
        "archives": [f"{name}.xcframework.zip" for name in (
            "MoltenVK", "MoltenVK_lib", "wgpu_native", "wgpu_native_framework", "shaderc", "spirv-cross")],
    },
    **{
        f"linux-{arch}": {
            "scripts": LIBRARY_SCRIPTS,
            "env": [],
            "archives": _bundles(["vulkan-loader", "wgpu_native", "shaderc", "spirv-cross"], f"linux-{arch}"),
        }
        for arch in ("x86_64", "aarch64")
    },
    "windows-x86_64": {
        "scripts": LIBRARY_SCRIPTS,
        "env": [],
        "archives": _bundles(["vulkan-loader", "wgpu_native", "shaderc", "spirv-cross"], "windows-x86_64"),
    },
    "android": {
        "scripts": ["build_wgpu.py", "build_shader_tools.py", "make_artifactbundle.py"],
        "env": ["ANDROID_NDK_VERSION"],
        "archives": [
            archive
            for abi in ("arm64-v8a", "x86_64")
            for archive in _bundles(["wgpu_native", "shaderc", "spirv-cross"], f"android-{abi}")
        ],
    },
    "wasm": {
        "scripts": ["build_shader_tools_wasm.py", "make_artifactbundle.py"],
        "env": ["SWIFT_VERSION"],
        "archives": _bundles(["shaderc", "spirv-cross"], "wasm32"),
    },
}


def log(message: str) -> None:
    print(f"[reuse] {message}", file=sys.stderr, flush=True)


def fingerprint(platform: str) -> str:
    spec = PLATFORMS[platform]
    digest = hashlib.sha256()
    digest.update(f"revision={os.environ.get('DEPS_REVISION', '')}\n".encode())
    for name in spec["env"]:
        value = os.environ.get(name)
        if not value:
            sys.exit(f"error: {name} is not set, and {platform}'s fingerprint depends on it")
        digest.update(f"{name}={value}\n".encode())
    for script in spec["scripts"]:
        # Line endings normalized: a Windows checkout has CRLF, and its
        # fingerprint has to match the one the release recorded on Linux.
        content = (SCRIPTS / script).read_bytes().replace(b"\r\n", b"\n")
        digest.update(f"{script}\n".encode())
        digest.update(hashlib.sha256(content).hexdigest().encode())
    return digest.hexdigest()


def _request(url: str, accept: str = "application/octet-stream") -> urllib.request.Request:
    request = urllib.request.Request(url, headers={"Accept": accept, "User-Agent": "NucleantVulkan-build-deps"})
    token = os.environ.get("GITHUB_TOKEN")
    if token and url.startswith("https://api.github.com/"):
        request.add_header("Authorization", f"Bearer {token}")
    return request


def latest_release(repository: str) -> dict | None:
    url = f"https://api.github.com/repos/{repository}/releases/latest"
    try:
        with urllib.request.urlopen(_request(url, "application/vnd.github+json"), timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def download(url: str) -> bytes:
    with urllib.request.urlopen(_request(url), timeout=600) as response:
        return response.read()


def with_version(archive: bytes, version: str) -> bytes:
    """The artifact bundle with every artifact in its info.json at `version`;
    every other entry copied as it is, attributes included."""
    source = zipfile.ZipFile(io.BytesIO(archive))
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as target:
        for entry in source.infolist():
            data = source.read(entry)
            if entry.filename.endswith(".artifactbundle/info.json"):
                info = json.loads(data)
                for artifact in info.get("artifacts", {}).values():
                    artifact["version"] = version
                data = (json.dumps(info, indent=2) + "\n").encode()
            target.writestr(entry, data, compress_type=entry.compress_type)
    return output.getvalue()


def fetch(platform: str, version: str, output: Path) -> bool:
    repository = os.environ.get("GITHUB_REPOSITORY")
    if not repository:
        log("GITHUB_REPOSITORY is not set: building")
        return False
    release = latest_release(repository)
    if release is None:
        log("no release yet: building")
        return False
    tag = release["tag_name"]
    assets = {asset["name"]: asset["browser_download_url"] for asset in release.get("assets", [])}
    if "deps.json" not in assets:
        log(f"{tag} has no deps.json (released before fingerprints were recorded): building")
        return False
    recorded = json.loads(download(assets["deps.json"])).get(platform)
    current = fingerprint(platform)
    if recorded != current:
        log(f"{platform} changed since {tag} ({recorded} → {current}): building")
        return False
    missing = [name for name in PLATFORMS[platform]["archives"] if name not in assets]
    if missing:
        log(f"{tag} lacks {', '.join(missing)}: building")
        return False

    # All of them or none: a platform half reused would be built over.
    archives = {}
    for name in PLATFORMS[platform]["archives"]:
        data = download(assets[name])
        if name.endswith(".artifactbundle.zip"):
            data = with_version(data, version)
        archives[name] = data
        log(f"{name} from {tag} ({len(data) // (1024 * 1024)} MB)")
    output.mkdir(parents=True, exist_ok=True)
    for name, data in archives.items():
        (output / name).write_bytes(data)
    log(f"{platform}: unchanged since {tag}, its libraries reused")
    return True


def set_output(name: str, value: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as file:
            file.write(f"{name}={value}\n")
    print(f"{name}={value}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    fetch_parser = commands.add_parser("fetch")
    fetch_parser.add_argument("platform", choices=sorted(PLATFORMS))
    fetch_parser.add_argument("--version", required=True)
    fetch_parser.add_argument("--output", type=Path, required=True)
    record_parser = commands.add_parser("record")
    record_parser.add_argument("platform", choices=sorted(PLATFORMS))
    record_parser.add_argument("--output", type=Path, required=True)
    commands.add_parser("collect").add_argument("directory", type=Path)
    commands.add_parser("fingerprint").add_argument("platform", choices=sorted(PLATFORMS))
    args = parser.parse_args()

    if args.command == "fetch":
        try:
            reused = fetch(args.platform, args.version, args.output)
        except Exception as error:  # a network hiccup costs a build, not the job
            log(f"could not check the last release ({error}): building")
            reused = False
        set_output("reused", "true" if reused else "false")
    elif args.command == "record":
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / f"fingerprint-{args.platform}.txt").write_text(fingerprint(args.platform) + "\n")
    elif args.command == "collect":
        recorded = {
            path.stem.removeprefix("fingerprint-"): path.read_text().strip()
            for path in sorted(args.directory.glob("fingerprint-*.txt"))
        }
        missing = sorted(set(PLATFORMS) - set(recorded))
        if missing:
            sys.exit(f"error: no fingerprint for {', '.join(missing)}")
        print(json.dumps(recorded, indent=2))
    else:
        print(fingerprint(args.platform))
    return 0


if __name__ == "__main__":
    sys.exit(main())
