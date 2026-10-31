#!/usr/bin/env python3
"""Build NucleantVulkanTests for WebAssembly and run them in headless Chrome.

On wasm the Vulkan API is implemented on the browser's WebGPU (see
Sources/CVulkanWasm and Web/nucleant-webgpu.js), so the tests can only run
where WebGPU exists: in a browser. This builds the test product with the wasm
Swift SDK, serves the package over http://127.0.0.1 (WebGPU needs a secure
context), opens Web/test/index.html in headless Chrome and relays the test
output. The exit status is the tests' — plus failure if any WebGPU
validation error happened, which the Vulkan validation layers would have
flagged on a native driver.

    python3 scripts/run_wasm_tests.py [--chrome PATH] [-- <test arguments>]

Chrome: --chrome, else $CHROME, else the usual install locations. Any recent
Chrome works (WebGPU and JSPI are on by default since Chrome 137); Chrome for
Testing can be fetched with `npx @puppeteer/browsers install chrome@stable`.
Needs a matching Swift toolchain + wasm SDK (the same lookup as
build_shader_tools_wasm.py) and Web/naga_webgpu.wasm (build_naga_wasm.py).
"""

from __future__ import annotations

import argparse
import functools
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from pathlib import Path

PACKAGE_ROOT = Path(__file__).resolve().parent.parent
SCRATCH = PACKAGE_ROOT / ".build" / "wasm"
VERSION_RE = re.compile(r"(\d+\.\d+(?:\.\d+)?)")

CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
]


def find_wasm_sdk() -> tuple[str, str]:
    """(swift executable, SDK id) for the newest installed *_wasm SDK whose toolchain exists."""
    roots = [Path.home() / "Library" / "org.swift.swiftpm" / "swift-sdks", Path.home() / ".swiftpm" / "swift-sdks"]
    for root in roots:
        for bundle in sorted(root.glob("*_wasm.artifactbundle"), reverse=True):
            sdk = bundle.name.removesuffix(".artifactbundle")
            version = VERSION_RE.search(sdk).group(1)
            for base in (Path.home() / "Library" / "Developer" / "Toolchains", Path("/Library/Developer/Toolchains")):
                swift = base / f"swift-{version}-RELEASE.xctoolchain" / "usr" / "bin" / "swift"
                if swift.is_file():
                    return str(swift), sdk
    sys.exit("error: no wasm Swift SDK with a matching toolchain found "
             "(https://www.swift.org/documentation/articles/wasm-getting-started.html)")


def find_chrome(explicit: str | None) -> str:
    for candidate in [explicit, os.environ.get("CHROME"), *CHROME_CANDIDATES]:
        if candidate and Path(candidate).is_file():
            return candidate
    sys.exit("error: no Chrome found; pass --chrome PATH or set CHROME")


def build_tests() -> Path:
    swift, sdk = find_wasm_sdk()
    env = dict(os.environ, WASM_BUILD="1")
    # The test product, not every target: the RenderNodeBuilder plugin's
    # generator runs on the build machine and isn't built for wasm.
    command = [swift, "build", "--product", "NucleantVulkanPackageTests", "--swift-sdk", sdk,
               "--scratch-path", str(SCRATCH)]
    print("+", " ".join(command), flush=True)
    if subprocess.run(command, cwd=PACKAGE_ROOT, env=env).returncode != 0:
        sys.exit("error: building the tests for wasm failed")
    products = sorted((SCRATCH / "debug").glob("NucleantVulkanPackageTests.*"))
    products = [p for p in products if p.suffix in (".wasm", ".xctest") and p.is_file()]
    if not products:
        sys.exit(f"error: no test product under {SCRATCH / 'debug'}")
    return products[0]


class Handler(http.server.SimpleHTTPRequestHandler):
    """Serves the package; /log and /done are the page reporting back."""

    done = threading.Event()
    status = 1

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8", "replace")
        if self.path == "/log":
            print(body, flush=True)
        elif self.path == "/done":
            Handler.status = int(body or 1)
            Handler.done.set()
        self.send_response(204)
        self.end_headers()

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, *args):
        pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--chrome", help="Chrome executable")
    parser.add_argument("--timeout", type=float, default=300, help="seconds before giving up")
    parser.add_argument("--headed", action="store_true", help="show the browser window")
    parser.add_argument("test_args", nargs="*", help="arguments for the test runner (after --)")
    args = parser.parse_args(argv)

    if not (PACKAGE_ROOT / "Web" / "naga_webgpu.wasm").is_file():
        sys.exit("error: Web/naga_webgpu.wasm is missing; run scripts/build_naga_wasm.py")
    chrome = find_chrome(args.chrome)
    product = build_tests()

    handler = functools.partial(Handler, directory=str(PACKAGE_ROOT))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    query = urllib.parse.urlencode({
        "wasm": "/" + product.relative_to(PACKAGE_ROOT).as_posix(),
        # The tests are Swift Testing; SwiftPM's runner defaults to XCTest.
        "args": json.dumps(["--testing-library", "swift-testing", *args.test_args]),
    })
    url = f"http://127.0.0.1:{port}/Web/test/index.html?{query}"
    print(f"[run_wasm_tests] {url}", flush=True)

    profile = tempfile.mkdtemp(prefix="nucleant-wasm-tests-")
    command = [
        chrome,
        f"--user-data-dir={profile}",
        "--no-first-run",
        "--no-default-browser-check",
        "--enable-unsafe-webgpu",
        "--remote-debugging-port=0",
        url,
    ]
    if not args.headed:
        command.insert(1, "--headless=new")
    browser = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        finished = Handler.done.wait(args.timeout)
    finally:
        browser.terminate()
        try:
            browser.wait(10)
        except subprocess.TimeoutExpired:
            browser.kill()
        server.shutdown()
        shutil.rmtree(profile, ignore_errors=True)
    if not finished:
        print(f"[run_wasm_tests] timed out after {args.timeout:.0f}s", flush=True)
        return 1
    print(f"[run_wasm_tests] exit status {Handler.status}", flush=True)
    return Handler.status


if __name__ == "__main__":
    sys.exit(main())
