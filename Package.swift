// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

/// Build against the sibling checkouts (`../NucleantGeometry`) or against GitHub.
///
/// Decided the same way in every Nucleant package, so one setting covers the
/// whole chain: `NUCLEANT_LOCAL_DEV=1|0` in the environment wins; otherwise
/// local when the sibling checkout exists next to this package — true in a
/// development tree, never for a clone SwiftPM (or Xcode) made in a
/// `checkouts` directory: there the "sibling" is the dependency's own
/// checkout, put next to this one by the same resolution, and taking it as a
/// path dependency changes the graph under the resolver ("exhausted attempts
/// to resolve"). Path dependencies are not allowed in a package fetched by
/// version or revision anyway, so a hardcoded `true` breaks every consumer.
let localDev: Bool = {
    if let flag = ProcessInfo.processInfo.environment["NUCLEANT_LOCAL_DEV"] {
        return ["1", "true", "yes"].contains(flag.lowercased())
    }
    let siblings = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    return siblings.lastPathComponent != "checkouts"
        && FileManager.default.fileExists(atPath: siblings.appendingPathComponent("NucleantGeometry").path)
}()

func getPlatformTarget() -> PackageDescription.Platform {
    // Package.swift is always compiled and run by the *host* toolchain, even
    // when the target platform differs (e.g. cross-compiling to Android from
    // a Linux or macOS host) — so `#if os(...)` alone can only ever tell us
    // the host, not an explicit cross-compile target. Linux needs no such
    // override: building natively on Linux, the host *is* the target, so
    // `#if os(Linux)` is sufficient and `swift build` just works with no
    // extra flags. Android has no such thing as "native"; it's always a
    // cross-compile, so it stays an explicit opt-in via env var.
    //
    // SWIFT_ANDROID_HOME is the signal, because it is what pyswiftkit-builder
    // actually exports and what CPython, PySwiftKit and PyNucleantUI already
    // test. ANDROID_BUILD stays accepted for a hand-driven `swift build`, but
    // on its own it was never set by the wheel build — which made this whole
    // branch dead code and silently routed Android builds to `.linux`.
    let env = ProcessInfo.processInfo.environment
    if env["SWIFT_ANDROID_HOME"] != nil || env["ANDROID_BUILD"] != nil {
        return .android
    }
    // WebAssembly (`swift build --swift-sdk <version>_wasm`) is a
    // cross-compile from any host, same as Android, so it is the same kind of
    // explicit opt-in.
    if env["WASM_BUILD"] == "1" {
        return .wasi
    }
#if os(Linux)
    return .linux
#else
    return .macOS
#endif
}

/// Vendored Android artifacts for the ABI currently being built.
///
/// Android builds one architecture per `swift build`, so unlike Linux there is
/// no single lib directory — the ABI comes from the environment
/// (`SWIFT_ANDROID_ABI`, else derived from the target triple in
/// `SWIFT_TRIPLE`). Nothing is probed for existence here: a missing directory
/// has to fail at link time with a real message, not silently resolve to some
/// other architecture's binaries.
func androidABI() -> String {
    let env = ProcessInfo.processInfo.environment
    if let abi = env["SWIFT_ANDROID_ABI"], !abi.isEmpty {
        return abi
    }
    let triple = env["SWIFT_TRIPLE"] ?? ""
    switch triple.split(separator: "-").first.map(String.init) ?? "" {
    case "aarch64": return "arm64-v8a"
    case "x86_64":  return "x86_64"
    case "armv7":   return "armeabi-v7a"
    default:        return "arm64-v8a"
    }
}

func androidLibDir() -> String {
    let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return packageRoot
        .appendingPathComponent("Dependencies/android/\(androidABI())/lib")
        .path
}

/// Vendored wasm32-wasip1 archives (scripts/build_shader_tools_wasm.py).
func wasmLibDir() -> String {
    let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return packageRoot.appendingPathComponent("Dependencies/wasm/lib").path
}

let platformTarget = getPlatformTarget()

// Set by pyswiftkit-builder for a wheel build. It distinguishes the two macOS
// modes — `uv run` against a wheel, versus the Xcode app that embeds this
// package — which differ in whether a dependency should be a bare dylib or a
// framework bundle. See the MoltenVK binary targets below.
let PIP_MODE = ProcessInfo.processInfo.environment["PIP_MODE"] == "1"

// Opt-in only, never the default: Android's ThorVG zero-copy render target
// normally imports via VK_KHR_external_memory_fd, same as Linux/Wayland. Set
// this to build the AHardwareBuffer path instead — confirmed much slower on
// real Android hardware, so it exists purely for cases where the fd path
// isn't usable (e.g. an emulator whose virtualized Vulkan driver doesn't
// expose VK_KHR_external_memory_fd regardless of host GPU passthrough).
// Produces a separate build, same pattern as PIP_MODE above — not a runtime
// fallback.
let ANDROID_USE_AHARDWAREBUFFER = ProcessInfo.processInfo.environment["NUCLEANT_ANDROID_USE_AHARDWAREBUFFER"] == "1"

/// Each prebuilt archive on the latest GitHub release, by file name: its URL
/// and checksum. Written here by .github/workflows/release.yml, which commits
/// it to master with the release — so master and the release's tag both
/// build from exactly the archives on that release. In this file, not one it
/// reads, because SwiftPM caches a manifest's evaluation by its text (and
/// environment), not by the files it looks at. Empty only before the first
/// release.
let releasedVulkan: [String: (url: String, checksum: String)] = [
    "MoltenVK.xcframework.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/MoltenVK.xcframework.zip",
        checksum: "2eee11428ac9e35dd530f6f905e3392e9b5ce99abf2e80ab87bc87e3610c80fe"
    ),
    "MoltenVK_lib.xcframework.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/MoltenVK_lib.xcframework.zip",
        checksum: "ba1d657c32465374fe65b1ba92b8d4bd21236b94ad741702bc6bd01d58068bdd"
    ),
    "shaderc-android-arm64-v8a.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/shaderc-android-arm64-v8a.artifactbundle.zip",
        checksum: "6501d81ebfc8cb187b2c821476e6c5cfdb0168a6c05591d9ad38bdcbcb79ae98"
    ),
    "shaderc-android-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/shaderc-android-x86_64.artifactbundle.zip",
        checksum: "cac64c025be9f9fd4a61fabdbe9c0cff5da2f33acf352d137c983b2c44fa63c2"
    ),
    "shaderc-linux-aarch64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/shaderc-linux-aarch64.artifactbundle.zip",
        checksum: "b0e7799a865572cb272518b16d5dc77f18780319aa1bb2016b344d8b9e3a054b"
    ),
    "shaderc-linux-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/shaderc-linux-x86_64.artifactbundle.zip",
        checksum: "eaa2c809b543e8b7c474e53ebeee7249fed39e4d764a18f8489e48dba5e1024d"
    ),
    "shaderc-wasm32.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/shaderc-wasm32.artifactbundle.zip",
        checksum: "9866d78b058d24e298a6079001056301eb5fbfe76f1aff782c4a64908e33adc4"
    ),
    "shaderc.xcframework.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/shaderc.xcframework.zip",
        checksum: "d2ef8e513a034ab9b43376d2edcc9b2a311628db3a4162255a2a815ef2b1adc3"
    ),
    "spirv-cross-android-arm64-v8a.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/spirv-cross-android-arm64-v8a.artifactbundle.zip",
        checksum: "90399471e33fa83f97e0113bfe218a99f2acbd41a737c2e92b91b4beeb7fda0e"
    ),
    "spirv-cross-android-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/spirv-cross-android-x86_64.artifactbundle.zip",
        checksum: "8970da46e691c14a93804d0893b6ef8a378fe8738e9f25eb7a3d7647e24a404d"
    ),
    "spirv-cross-linux-aarch64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/spirv-cross-linux-aarch64.artifactbundle.zip",
        checksum: "4eacefd0ffea12b916a12b23fbb65cd668e565455fdc44f57ce99c2dc891ac98"
    ),
    "spirv-cross-linux-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/spirv-cross-linux-x86_64.artifactbundle.zip",
        checksum: "7875c15918ef4119f0635b6cff15a0f66551a06dcd1991a205cec3dde5202e9c"
    ),
    "spirv-cross-wasm32.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/spirv-cross-wasm32.artifactbundle.zip",
        checksum: "25908490640c00ad10ebe77ee2bc055f6282d8388d4738322590441b093bcfa4"
    ),
    "spirv-cross.xcframework.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/spirv-cross.xcframework.zip",
        checksum: "ea5c612603f96d49c5b399fc7ba31545fd951dd96a51fc4b8409e57d3215beb1"
    ),
    "vulkan-loader-linux-aarch64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/vulkan-loader-linux-aarch64.artifactbundle.zip",
        checksum: "1ea7ad49acda0e90789d737b155c22bef0209204e754c2f9547c54aff649b4d3"
    ),
    "vulkan-loader-linux-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/vulkan-loader-linux-x86_64.artifactbundle.zip",
        checksum: "65935f94c139e819fd30f8a1bd81353c68351e74f540d1f94da992d0cd72ba82"
    ),
    "wgpu_native-android-arm64-v8a.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/wgpu_native-android-arm64-v8a.artifactbundle.zip",
        checksum: "01d5cc2f145cdc660c28d137ce46266a6f56d8e73db1a564ebab0e137c5f8e41"
    ),
    "wgpu_native-android-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/wgpu_native-android-x86_64.artifactbundle.zip",
        checksum: "30b1a1cfa308f9377cba8886af0456afd36ce33365da361fac91aae31aa259ec"
    ),
    "wgpu_native-linux-aarch64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/wgpu_native-linux-aarch64.artifactbundle.zip",
        checksum: "58969e0d94dd9f07047d5d0f2b9aaa45ab19395d5eb3d974b936930a3c7c6acf"
    ),
    "wgpu_native-linux-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/wgpu_native-linux-x86_64.artifactbundle.zip",
        checksum: "3ca48790620d3e1bb056c39581d3dea16b493802f387118d8cdf17951b814ba0"
    ),
    "wgpu_native.xcframework.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/wgpu_native.xcframework.zip",
        checksum: "b670b3e97e84371ae9aeb8a5db744c08cae647919d8c2440285d9a36812a881c"
    ),
    "wgpu_native_framework.xcframework.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.1/wgpu_native_framework.xcframework.zip",
        checksum: "2b7968fa6d8789ee09bd57d7a540b29777701aa67b44083f2d03744992772b72"
    ),
]

/// With NUCLEANT_VULKAN_ARTIFACTS=1, the archives in Artifacts/ — the ones
/// .github/workflows/build-deps.yml has just built, put there to build and
/// test against. They come before the release's, which they are about to
/// replace.
let localArtifacts = ProcessInfo.processInfo.environment["NUCLEANT_VULKAN_ARTIFACTS"] == "1"

/// The libraries come prebuilt: from Artifacts/ (above), or from the release.
/// Otherwise — before the first release — from the vendored Dependencies/.
let prebuiltVulkan = localArtifacts || !releasedVulkan.isEmpty

/// A prebuilt archive as a binary target: Artifacts/, else the release's URL.
func prebuiltBinary(_ name: String, _ archive: String) -> Target {
    if !localArtifacts, let release = releasedVulkan[archive] {
        return .binaryTarget(name: name, url: release.url, checksum: release.checksum)
    }
    return .binaryTarget(name: name, path: "Artifacts/\(archive)")
}

/// One library of Linux, Android or wasm as its own artifact bundle
/// (scripts/make_artifactbundle.py), named after the library, the platform
/// and the architecture — `wgpu_native-linux-x86_64.artifactbundle.zip` —
/// the way each library is its own xcframework zip on Apple's platforms. The
/// binary target has the library's name too. On Linux and Android the bundle
/// holds the shared library itself — SwiftPM copies it next to the product
/// and links it, so libwgpu_native.so stays the one copy ThorVG's library
/// links too, and an app ships every one of them: on Linux nothing but the
/// GPU driver comes from the machine.
func prebuiltLibrary(_ library: String) -> Target {
    let platform: String
    switch platformTarget {
    case .wasi:
        platform = "wasm32"
    case .android:
        platform = "android-\(androidABI())"
    default:
        // Linux builds are native, so the host's architecture is the target's.
#if arch(arm64)
        platform = "linux-aarch64"
#else
        platform = "linux-x86_64"
#endif
    }
    return prebuiltBinary(library, "\(library)-\(platform).artifactbundle.zip")
}

/// vulkanTargets() over the prebuilt libraries. No unsafeFlags — SwiftPM
/// refuses them in a package depended on by version — so the binary targets
/// give the libraries and the C targets keep only their own headers.
func prebuiltVulkanTargets() -> [Target] {
    switch platformTarget {
    case .linux:
        return [
            // libvulkan.so (the Khronos loader), libwgpu_native.so,
            // libshaderc_shared.so, libspirv-cross-c-shared.so — each built
            // from the same sources as on the other platforms, none of them
            // the system's.
            prebuiltLibrary("vulkan-loader"),
            prebuiltLibrary("wgpu_native"),
            prebuiltLibrary("shaderc"),
            prebuiltLibrary("spirv-cross"),
            // Vulkan-Headers 1.4.334, as Apple's CVulkan, with every WSI.
            .target(
                name: "CVulkan",
                dependencies: ["vulkan-loader"],
                path: "Sources/CVulkanLinuxPrebuilt",
                sources: ["stub.c"],
                publicHeadersPath: "include"
            ),
            // shaderc's and spirv-cross's headers: the Android targets', of
            // the same refs.
            .target(
                name: "CShaderc",
                dependencies: ["shaderc"],
                path: "Sources/CShadercAndroid",
                sources: ["stub.c"],
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath("."),
                ]
            ),
            .target(
                name: "CSPIRVCross",
                dependencies: ["spirv-cross"],
                path: "Sources/CSPIRVCrossAndroid",
                sources: ["stub.c"],
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath("."),
                ]
            ),
            .target(
                name: "CWgpu",
                dependencies: ["wgpu_native"],
                path: "Sources/CWgpuLinux",
                sources: ["stub.c"],
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath("."),
                ]
            ),
        ]
    case .android:
        return [
            .systemLibrary(
                name: "CVulkan",
                path: "Sources/CVulkanAndroid"
            ),
            // libwgpu_native.so, libshaderc_shared.so,
            // libspirv-cross-c-shared.so — staged into the app as before.
            prebuiltLibrary("wgpu_native"),
            prebuiltLibrary("shaderc"),
            prebuiltLibrary("spirv-cross"),
            .target(
                name: "CShaderc",
                dependencies: ["shaderc"],
                path: "Sources/CShadercAndroid",
                sources: ["stub.c"],
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath("."),
                ]
            ),
            .target(
                name: "CSPIRVCross",
                dependencies: ["spirv-cross"],
                path: "Sources/CSPIRVCrossAndroid",
                sources: ["stub.c"],
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath("."),
                ]
            ),
            .target(
                name: "CWgpu",
                dependencies: ["wgpu_native"],
                path: "Sources/CWgpuLinux",
                sources: ["stub.c"],
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath("."),
                ]
            ),
        ]
    case .wasi:
        return [
            .target(
                name: "CVulkan",
                path: "Sources/CVulkanWasm",
                sources: [
                    "vkw_device.c",
                    "vkw_memory.c",
                    "vkw_descriptor.c",
                    "vkw_pipeline.c",
                    "vkw_command.c",
                    "vkw_queue.c",
                ],
                publicHeadersPath: "include"
            ),
            // libshaderc_combined.a, libspirv-cross.a (static: the browser
            // has no loader).
            prebuiltLibrary("shaderc"),
            prebuiltLibrary("spirv-cross"),
            .target(
                name: "CShaderc",
                dependencies: ["shaderc"],
                path: "Sources/CShadercWasm",
                sources: ["stub.c"],
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath("."),
                ],
                linkerSettings: [
                    .linkedLibrary("c++"),
                ]
            ),
            .target(
                name: "CSPIRVCross",
                dependencies: ["spirv-cross"],
                path: "Sources/CSPIRVCrossWasm",
                sources: ["stub.c"],
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath("."),
                ],
                linkerSettings: [
                    .linkedLibrary("c++"),
                ]
            ),
            .target(
                name: "CWgpu",
                path: "Sources/CWgpuWasm",
                sources: ["webgpu_wasm.c"],
                publicHeadersPath: "include"
            ),
        ]
    default:
        var targets: [Target] = [prebuiltBinary("MoltenVK", "MoltenVK.xcframework.zip")]
        if PIP_MODE {
            targets.append(prebuiltBinary("MoltenVKLib", "MoltenVK_lib.xcframework.zip"))
        }
        targets += [
            .target(
                name: "CVulkan",
                dependencies: PIP_MODE ? [
                    .byName(
                        name: "MoltenVKLib",
                        condition: .when(platforms: [.macOS])
                    ),
                    .byName(
                        name: "MoltenVK",
                        condition: .when(platforms: [.iOS, .tvOS, .macCatalyst])
                    )
                ] : [
                    .byName(
                        name: "MoltenVK",
                        condition: .when(platforms: [.iOS, .macOS, .tvOS, .macCatalyst])
                    )
                ],
                sources: ["stub.c"],
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath(".")
                ]
            ),
            prebuiltBinary("CWgpu", "wgpu_native.xcframework.zip"),
            prebuiltBinary("CWgpuFW", "wgpu_native_framework.xcframework.zip"),
            prebuiltBinary("shaderc", "shaderc.xcframework.zip"),
            prebuiltBinary("spirv-cross", "spirv-cross.xcframework.zip"),
            .target(
                name: "CShaderc",
                dependencies: ["shaderc"],
                sources: ["stub.c"],
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath(".")
                ],
                linkerSettings: [
                    .linkedLibrary("c++")
                ]
            ),
            .target(
                name: "CSPIRVCross",
                dependencies: ["spirv-cross"],
                sources: ["stub.c"],
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath(".")
                ],
                linkerSettings: [
                    .linkedLibrary("c++")
                ]
            ),
        ]
        return targets
    }
}


func getDependencies() -> [Package.Dependency] {
    var deps = [Package.Dependency]()
    if localDev {
        deps.append(.package(path: "../NucleantGeometry"))
    } else {
        deps.append(.package(url: "https://github.com/NucleantUI/NucleantGeometry", .upToNextMinor(from: "0.0.1")))
    }
    return deps
}



func vulkanTargets() -> [Target] {
    if prebuiltVulkan {
        return prebuiltVulkanTargets()
    }
    var targets: [Target] = []

    switch platformTarget {
    case let p where p == .linux:
        // System Vulkan loader via pkg-config.
        // WSI backends auto-detected from installed dev headers in CVulkanLinux/shim.h.
        // Requires: apt install libvulkan-dev (+ libwayland-dev/libxcb1-dev/
        // libx11-dev for Wayland/XCB/Xlib surface support — see
        // Dependencies/linux/README.md).
        targets.append(
            .systemLibrary(
                name: "CVulkan",
                path: "Sources/CVulkanLinux",
                pkgConfig: "vulkan",
                providers: [
                    .apt(["libvulkan-dev", "libwayland-dev", "libxcb1-dev", "libx11-dev"])
                ]
            )
        )
    case let p where p == .android:
        // Vulkan is built into Android (API 24+); NDK provides headers and libvulkan.so.
        targets.append(
            .systemLibrary(
                name: "CVulkan",
                path: "Sources/CVulkanAndroid"
            )
        )
    case let p where p == .wasi:
        // WebAssembly: no Vulkan driver exists in a browser, so this target
        // *is* the driver — the Vulkan API implemented on the browser's
        // WebGPU, the way MoltenVK implements it on Metal. The C side keeps
        // the Vulkan state; Web/nucleant-webgpu.js makes the WebGPU calls
        // (imported as the "nucleant_webgpu" wasm module) and
        // Web/naga_webgpu.wasm (NagaWebGPU/) turns SPIR-V into WGSL.
        targets.append(
            .target(
                name: "CVulkan",
                path: "Sources/CVulkanWasm",
                sources: [
                    "vkw_device.c",
                    "vkw_memory.c",
                    "vkw_descriptor.c",
                    "vkw_pipeline.c",
                    "vkw_command.c",
                    "vkw_queue.c",
                ],
                publicHeadersPath: "include"
            )
        )
    default:
        // Apple: bundled Vulkan headers + MoltenVK xcframework (Vulkan -> Metal).
        // Two forms of the same Mach-O, the way wgpu already has two:
        //   • MoltenVK    — MoltenVK.framework (@rpath/MoltenVK.framework/MoltenVK)
        //   • MoltenVKLib — bare libMoltenVK.dylib (@rpath/libMoltenVK.dylib)
        // A wheel vendors plain files into nucleant/.dylibs, so PIP_MODE takes
        // the dylib on macOS; Xcode embed mode keeps the framework, and iOS
        // has no choice — it links frameworks. Both are produced by
        // scripts/build_vulkan.py from one build.
        targets.append(
            .binaryTarget(
                name: "MoltenVK",
                path: "Dependencies/macos/MoltenVK.xcframework"
            )
        )
        if PIP_MODE {
            targets.append(
                .binaryTarget(
                    name: "MoltenVKLib",
                    path: "Dependencies/macos/MoltenVK_lib.xcframework"
                )
            )
        }

        targets.append(
            .target(
                name: "CVulkan",
                dependencies: PIP_MODE ? [
                    .byName(
                        name: "MoltenVKLib",
                        condition: .when(platforms: [.macOS])
                    ),
                    .byName(
                        name: "MoltenVK",
                        condition: .when(platforms: [.iOS, .tvOS, .macCatalyst])
                    )
                ] : [
                    .byName(
                        name: "MoltenVK",
                        condition: .when(platforms: [.iOS, .macOS, .tvOS, .macCatalyst])
                    )
                ],
                sources: ["stub.c"],
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath(".")
                ]
            )
        )
    }
    if platformTarget == .android {
        // Android has no system package manager to resolve these from and no
        // xcframework support, so all three are vendored per-ABI under
        // Dependencies/android/<abi>/lib — the same role Dependencies/linux
        // plays on Linux. Header search paths are private to the declaring
        // target and do not propagate to importers, so each C target keeps its
        // own publicHeadersPath exactly as the Linux branch does.
        let libDir = androidLibDir()

        targets.append(
            .target(
                name: "CShaderc",
                path: "Sources/CShadercAndroid",
                sources: ["stub.c"],
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath("."),
                ],
                linkerSettings: [
                    .linkedLibrary("shaderc_shared"),
                    .unsafeFlags(["-L\(libDir)"]),
                ]
            )
        )
        targets.append(
            .target(
                name: "CSPIRVCross",
                path: "Sources/CSPIRVCrossAndroid",
                // spirv_cross_c.h sits beside shim.h in include/ and is
                // included unprefixed, matching the Linux shim's spelling.
                sources: ["stub.c"],
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath("."),
                ],
                linkerSettings: [
                    .linkedLibrary("spirv-cross-c-shared"),
                    .unsafeFlags(["-L\(libDir)"]),
                ]
            )
        )
        // No -rpath: on Android the loader resolves DT_NEEDED out of the app's
        // native library directory, which is where Gradle stages these .so
        // files. An rpath baked at build time would point at a host path that
        // does not exist on device.
        targets.append(
            .target(
                name: "CWgpu",
                path: "Sources/CWgpuLinux",
                sources: ["stub.c"],
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath("."),
                ],
                linkerSettings: [
                    .linkedLibrary("wgpu_native"),
                    .unsafeFlags(["-L\(libDir)"]),
                ]
            )
        )
    } else if platformTarget == .wasi {
        // shaderc and spirv-cross compiled for wasm32-wasip1 and vendored as
        // static archives — the browser has no loader to resolve shared
        // libraries, so everything links into the one module. Headers sit in
        // each target's own include/, as on Android.
        let libDir = wasmLibDir()
        targets.append(
            .target(
                name: "CShaderc",
                path: "Sources/CShadercWasm",
                sources: ["stub.c"],
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath("."),
                ],
                linkerSettings: [
                    .linkedLibrary("shaderc_combined"),
                    .linkedLibrary("c++"),
                    .unsafeFlags(["-L\(libDir)"]),
                ]
            )
        )
        targets.append(
            .target(
                name: "CSPIRVCross",
                path: "Sources/CSPIRVCrossWasm",
                sources: ["stub.c"],
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath("."),
                ],
                linkerSettings: [
                    .linkedLibrary("spirv-cross-c"),
                    .linkedLibrary("spirv-cross-glsl"),
                    .linkedLibrary("spirv-cross-hlsl"),
                    .linkedLibrary("spirv-cross-msl"),
                    .linkedLibrary("spirv-cross-cpp"),
                    .linkedLibrary("spirv-cross-reflect"),
                    .linkedLibrary("spirv-cross-util"),
                    .linkedLibrary("spirv-cross-core"),
                    .linkedLibrary("c++"),
                    .unsafeFlags(["-L\(libDir)"]),
                ]
            )
        )
        // webgpu.h, the C API wgpu-native provides everywhere else, on the
        // browser's WebGPU — the same device the CVulkan target above runs
        // on (Web/nucleant-wgpu.js is its JS half). What WgpuContext and
        // ThorVG's wg engine draw through; same module name as the native
        // CWgpu so both `import CWgpu`.
        targets.append(
            .target(
                name: "CWgpu",
                path: "Sources/CWgpuWasm",
                sources: ["webgpu_wasm.c"],
                publicHeadersPath: "include"
            )
        )
    } else if platformTarget == .linux {
        // shaderc (GLSL -> SPIR-V) via system libshaderc-dev, discovered
        // through its shaderc.pc pkg-config file — same shim-header pattern
        // as CVulkanLinux above.
        targets.append(
            .systemLibrary(
                name: "CShaderc",
                path: "Sources/CShadercLinux",
                pkgConfig: "shaderc",
                providers: [
                    .apt(["libshaderc-dev"])
                ]
            )
        )
        // spirv-cross (SPIR-V -> MSL/HLSL/GLSL) via system
        // libspirv-cross-c-shared-dev, discovered through its
        // spirv-cross-c-shared.pc pkg-config file.
        targets.append(
            .systemLibrary(
                name: "CSPIRVCross",
                path: "Sources/CSPIRVCrossLinux",
                pkgConfig: "spirv-cross-c-shared",
                providers: [
                    .apt(["libspirv-cross-c-shared-dev"])
                ]
            )
        )
        // wgpu-native isn't packaged by any distro, so unlike
        // CVulkan/CShaderc/CSPIRVCross above there's no system version to
        // resolve against — it's vendored instead, the same way the
        // macOS/iOS xcframework below is: run scripts/build_wgpu.py
        // --prefix Dependencies/linux first (builds wgpu-native, copies
        // libwgpu_native.so into Dependencies/linux/lib, and — separately —
        // wgpu.h/webgpu.h are vendored into this target's own include/, the
        // same way CThorVG vendors thorvg_capi.h: cSettings/header search
        // paths are private to the target that declares them and don't
        // propagate to importers, so an external -I here wouldn't be seen
        // by code doing `import CWgpu` — only publicHeadersPath is). See
        // Dependencies/linux/README.md.
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let linuxLibDir = packageRoot.appendingPathComponent("Dependencies/linux/lib").path
        targets.append(
            .target(
                name: "CWgpu",
                path: "Sources/CWgpuLinux",
                sources: ["stub.c"],
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath("."),
                ],
                linkerSettings: [
                    .linkedLibrary("wgpu_native"),
                    .unsafeFlags([
                        "-L\(linuxLibDir)",
                        "-Xlinker", "-rpath", "-Xlinker", linuxLibDir,
                    ]),
                ]
            )
        )
    } else {
        // wgpu-native (v29.0.1.1), built by scripts/build_wgpu.py from NucleantUI's
        // fork. Two forms because iOS links frameworks, not bare dylibs:
        //   • macOS — the library xcframework: bare libwgpu_native.dylib
        //     (@rpath/libwgpu_native.dylib), module `CWgpu`.
        //   • iOS — the framework xcframework: wgpu_native.framework
        //     (@rpath/wgpu_native.framework/wgpu_native), module `wgpu_native` —
        //     the same reference ThorVG's iOS framework links, so the process
        //     shares one embedded copy.
        targets.append(
            .binaryTarget(
                name: "CWgpu",
                path: "Dependencies/macos/wgpu_native.xcframework"
            )
        )
        targets.append(
            .binaryTarget(
                name: "CWgpuFW",
                path: "Dependencies/macos/wgpu_native_framework.xcframework"
            )
        )
        targets.append(contentsOf: [
            .binaryTarget(
                 name: "shaderc",
                 path: "Dependencies/macos/shaderc.xcframework"
             ),

             // spirv-cross xcframework (SPIR-V -> MSL/HLSL cross-compiler)
             .binaryTarget(
                 name: "spirv-cross",
                 path: "Dependencies/macos/spirv-cross.xcframework"
             ),
             // CShaderc - C wrapper for shaderc (GLSL -> SPIR-V compiler)
             .target(
                 name: "CShaderc",
                 dependencies: ["shaderc"],
                 //path: "Dependencies/CShaderc",
                 sources: ["stub.c"],
                 publicHeadersPath: "include",
                 cSettings: [
                     .headerSearchPath(".")
                 ],
                 linkerSettings: [
                     .linkedLibrary("c++")
                 ]
             ),

             // CSPIRVCross - C wrapper for spirv-cross (SPIR-V -> MSL/HLSL)
             .target(
                 name: "CSPIRVCross",
                 dependencies: ["spirv-cross"],
                 //path: "Dependencies/CSPIRVCross",
                 sources: ["stub.c"],
                 publicHeadersPath: "include",
                 cSettings: [
                     .headerSearchPath(".")
                 ],
                 linkerSettings: [
                     .linkedLibrary("c++")
                 ]
             ),
        ])
    }
    return targets
}

func libraryTargets() -> [Target] {
    var targets = vulkanTargets()
    targets.append(.target(
        name: "NucleantShader",
        dependencies: [
            "CShaderc",
            "CSPIRVCross",
            //.product(name: "SulphurVulkan", package: "NucleantVulkan"),
            //.product(name: "VulkanCore", package: "NucleantVulkan")
            "CVulkan"
        ]
    ))
    // targets.append(.testTarget(
    //     name: "NucleantShaderTests",
    //     dependencies: [
    //         "NucleantShader",
    //         //.product(name: "VulkanCore", package: "NucleantVulkan")
    //         "CVulkan"
    //     ]
    // ))
    return targets
}

func mainTargets() -> [Target] {
    [
        .target(
            name: "VulkanCore",
            dependencies: [
                "CVulkan",
                .product(name: "NucleantGeometry", package: "NucleantGeometry")
            ]
        ),
        .target(
            name: "NucleantVulkan",
            dependencies: {
                // macOS/Linux link the bare dylib/.so (module CWgpu); iOS
                // links the framework (module wgpu_native) — see the binary
                // targets above. WgpuContext / VulkanRenderEngine import the
                // right one per platform. SPM links + embeds whichever
                // applies. `CWgpuFW` is only ever declared as a target in the
                // Apple (non-Linux/Android) branch of vulkanTargets(), so the
                // by-name reference to it must be left out entirely on
                // Linux/Android — a `.when(platforms:)` condition only gates
                // linking, not whether the referenced target has to exist.
                var deps: [Target.Dependency] = [
                    "VulkanCore",
                    "NucleantShader"
                ]
                // .android included: the Android branch of vulkanTargets()
                // declares its own CWgpu (vendored libwgpu_native.so), and
                // without it here the target exists but never links. On wasm
                // CWgpu is webgpu.h on the browser's WebGPU.
                deps.insert(.byName(name: "CWgpu", condition: .when(platforms: [.macOS, .linux, .android, .wasi])), at: 0)
                if platformTarget != .linux && platformTarget != .android && platformTarget != .wasi {
                    deps.append(.byName(name: "CWgpuFW", condition: .when(platforms: [.iOS])))
                }
                return deps
            }(),
            swiftSettings: ANDROID_USE_AHARDWAREBUFFER ? [.define("NUCLEANT_ANDROID_USE_AHARDWAREBUFFER")] : []
        ),
        .testTarget(
            name: "NucleantVulkanTests",
            dependencies: ["NucleantVulkan"]
        )
        
    ]
}


func getTargets() -> [Target] {
    var targets = mainTargets()
    targets.append(contentsOf: libraryTargets())
    return targets
}

func getProducts() -> [Product] {
    // CVulkan is a `.systemLibrary` target on Linux/Android; SwiftPM rejects
    // a product that bundles a system-library target alongside another
    // target ("system library product ... shouldn't have a type and contain
    // only one target"), so there it's left out of NucleantVulkan's product —
    // it's still reachable as an internal build dependency, just not
    // re-exported as part of this product's public target list.
    // On wasm CVulkan is an ordinary C target (the WebGPU-backed driver), so
    // it is re-exported the way the Apple one is.
    let vulkanTargets: [String] = platformTarget == .linux || platformTarget == .android
        ? ["NucleantVulkan"]
        : ["NucleantVulkan", "CVulkan"]
    return [
        .library(
            name: "NucleantVulkan",
            targets: vulkanTargets
        ),
        .library(
            name: "VulkanCore",
            targets: ["VulkanCore"]
        ),
        .library(
            name: "NucleantShader",
            targets: ["NucleantShader"]
        ),
    ]
}

let package = Package(
    name: "NucleantVulkan",
    platforms: [
        // iOS 17 (not 15): the render nodes use the Observation framework
        // (@Observable / withObservationTracking), whose floor is iOS 17 /
        // macOS 14 — so this is the exact parallel of the macOS(.v14) minimum.
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: getProducts(),
    dependencies: getDependencies(),
    targets: getTargets()
)
