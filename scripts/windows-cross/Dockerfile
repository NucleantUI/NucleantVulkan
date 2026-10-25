# Cross-compiles NucleantVulkan's Windows libraries (x86_64-pc-windows-msvc)
# from Linux, for checking the Windows builds without a Windows machine.
# build.sh beside this builds the image, every library and their artifact
# bundles; one script at a time:
#
#   docker build -t nucleant-windows-cross scripts/windows-cross
#   docker run --rm -v "$PWD:/src" -w /src nucleant-windows-cross \
#       python3 scripts/build_wgpu.py --windows
#
# The same scripts build natively on Windows (.github/workflows/build-deps.yml);
# here clang-cl, lld-link and llvm-lib stand in for MSVC's cl, link and lib,
# with the MSVC CRT and the Windows SDK that cargo-xwin downloads from
# Microsoft. The libraries come out MSVC-ABI DLLs with import libraries, the
# same as a native build's. CMake builds take the same CRT and SDK through
# toolchain.cmake (CMAKE_TOOLCHAIN_FILE, set below).
#
# Building the image accepts the Microsoft license for the CRT and SDK, as
# installing Visual Studio's build tools would.

FROM swift:6.3.3-noble

# Swift's toolchain has clang-cl and lld-link; LLVM 18 adds the rest of the
# MSVC-style tools (llvm-lib, llvm-rc, llvm-mt, llvm-ml), linked into
# /usr/local/bin under the names the builds look for. Not Ubuntu's unversioned
# clang package: it would replace Swift's clang in /usr/bin. libclang is for
# bindgen (wgpu-native's build script), gcc for cargo's host-side builds.
RUN apt-get update && apt-get install -y --no-install-recommends \
        llvm-18 libclang-18-dev gcc g++ \
        cmake ninja-build python3 git curl ca-certificates pkg-config \
    && rm -rf /var/lib/apt/lists/* \
    && for tool in llvm-lib llvm-rc llvm-mt llvm-ml llvm-dlltool llvm-readobj llvm-objdump; do \
           ln -sf "/usr/lib/llvm-18/bin/$tool" "/usr/local/bin/$tool"; \
       done

# Rust with the MSVC target, and cargo-xwin, which drives cargo through
# clang-cl/lld-link against its own download of the CRT and SDK — cached in
# the image, so a run needs no download.
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH \
    XWIN_ARCH=x86_64 XWIN_CACHE_DIR=/opt/xwin-cache
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --target x86_64-pc-windows-msvc \
    && cargo install --locked cargo-xwin \
    && rm -rf /opt/cargo/registry \
    && XWIN_ACCEPT_LICENSE=1 cargo xwin cache xwin \
    && rm -rf /opt/xwin-cache/xwin/dl /opt/xwin-cache/xwin/unpack

COPY toolchain.cmake override.cmake /opt/windows-cross/
ENV CMAKE_TOOLCHAIN_FILE=/opt/windows-cross/toolchain.cmake
