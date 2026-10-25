#!/bin/sh
# Cross-compiles every Windows library in the image this directory's
# Dockerfile makes, and packages them as the release's Windows artifact
# bundles into Artifacts/ — what build-deps.yml's windows job builds natively,
# and what Package.swift takes with NUCLEANT_VULKAN_ARTIFACTS=1:
#
#   scripts/windows-cross/build.sh            all four
#   scripts/windows-cross/build.sh --ref v29.0.1.3   wgpu-native at another ref
#
# Sources and builds go to scripts/.work/windows, the cargo registry and the
# Rust toolchains to Docker volumes, so a second run is incremental.
set -e
cd "$(dirname "$0")/../.."

docker build -t nucleant-windows-cross scripts/windows-cross

# The Docker VM's memory, not its CPUs, bounds the parallel compiles.
run() {
    docker run --rm -v "$PWD:/src" -w /src \
        -v nucleant-windows-cargo:/opt/cargo/registry -v nucleant-windows-rustup:/opt/rustup \
        -e XWIN_ACCEPT_LICENSE=1 -e CARGO_BUILD_JOBS=8 \
        nucleant-windows-cross "$@"
}
work=scripts/.work/windows

run python3 scripts/build_wgpu.py --windows --work-dir "$work" "$@"
run python3 scripts/build_vulkan.py --windows --work-dir "$work" --jobs 8
run python3 scripts/build_shader_tools.py --windows --work-dir "$work" --jobs 8

run sh -c '
    lib=Dependencies/windows
    for pair in vulkan-loader:vulkan-1 wgpu_native:wgpu_native \
                shaderc:shaderc_shared spirv-cross:spirv-cross-c-shared; do
        python3 scripts/make_artifactbundle.py --triple x86_64-unknown-windows-msvc \
            --library "$lib/lib/${pair#*:}.lib" --dll "$lib/bin/${pair#*:}.dll" \
            --name "${pair%%:*}-windows-x86_64" --output Artifacts --version 0.0.0
    done'
ls -l Artifacts/*-windows-x86_64.artifactbundle.zip
