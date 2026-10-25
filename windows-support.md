# prepare for windows support

dont know if we can use Docker to host some kind of windows environment to build the package
for windows, and test it that way.. same with temporary getting deps to work..

# configure action to also build dependencies for windows

you can always just test only building for windows..


---

# Status

## What is in place

- `Package.swift`: a `.windows` platform (native, `#if os(Windows)`), taking
  four artifact bundles, `<library>-windows-x86_64.artifactbundle.zip` —
  `vulkan-loader` (vulkan-1.dll), `wgpu_native`, `shaderc`, `spirv-cross`. Each
  holds the DLL's import library (`staticLibrary`, linked as `-l<name>`) and
  the DLL (`experimentalWindowsDLL`, which SwiftPM 6.3 copies next to the
  product). No unsafeFlags.
- `Sources/CVulkanWindowsPrebuilt`: Vulkan-Headers 1.4.334 with
  VK_KHR_win32_surface (windows.h types, via WinSDK).
- `VulkanRenderEngine(win32Instance:win32Window:getExtent:)`
  (`VulkanRenderEngine+Windows.swift`); the device enables
  VK_KHR_external_memory_win32 when the driver has it.
- `WgpuContext` on Windows exports each target's memory as an NT handle
  (`nativeVulkanExportedWin32Handle()`), through
  `wgpuDeviceCreateTextureWithExportedWin32Handle` — a new function in the
  wgpu-native fork, the Windows twin of the fd one (tag v29.0.1.3, which
  `WGPU_REF` builds).
- Scripts: `build_wgpu.py`, `build_vulkan.py`, `build_shader_tools.py` take
  `--windows` (the default on a Windows host); `make_artifactbundle.py` takes
  `--dll`.
- CI: `build-deps.yml` has `windows` (native MSVC build + bundles) and
  `windows-test` (fresh machine, Swift 6.3.3, Mesa lavapipe as the Vulkan
  driver, `swift test`). Run it with platform `windows` to try only that.
- Tests: `ShaderToolsTests` (shaderc, spirv-cross, loader — every platform, no
  GPU) and `Win32EngineTests` (the engine on a Win32 window, a texture through
  the GPU and back — Windows).

## Building the Windows libraries from a Mac or Linux (Docker)

    scripts/windows-cross/build.sh

Cross-compiles all four with clang-cl/lld-link against Microsoft's CRT and
SDK (cargo-xwin) and writes the bundles to `Artifacts/`. Same scripts as CI,
same MSVC ABI. It cannot run Swift for Windows (swift.org publishes no
Windows cross SDK), so the Swift side is checked by `windows-test` in CI.

## Real GPU tests: Linux Mint + QEMU

A Windows guest in plain QEMU (or dockur/windows) has no Vulkan driver: its
display adapter is emulated, and virtio-gpu's Vulkan (venus) has no Windows
guest driver. Options:

- Mesa lavapipe in the guest (what CI does): functional, software only.
- VFIO passthrough of a real GPU to the guest (IOMMU on, a GPU the host can
  give up): the vendor's Windows driver, real Vulkan acceleration.
- Bare-metal Windows (dual boot): the reference for performance.
