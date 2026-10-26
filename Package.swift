// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

/// Build against the sibling checkouts (`../NucleantGeometry`) or GitHub.
///
/// GitHub unless `NUCLEANT_LOCAL_DEV=1` is in the environment: the sibling
/// checkouts are used only when that turns them on, never just because they
/// are there. Every Nucleant package reads the same variable, so one setting
/// covers the whole chain.
let localDev: Bool = ["1", "true", "yes"].contains(
    (ProcessInfo.processInfo.environment["NUCLEANT_LOCAL_DEV"] ?? "").lowercased()
)

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
#elseif os(Windows)
    // Native, like Linux: the Windows toolchain builds for the machine it
    // runs on.
    return .windows
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
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/MoltenVK.xcframework.zip",
        checksum: "3b37dd7c253ebe1baee7fa481f87ea4ce2c33eab500fc746994992e29ba5a955"
    ),
    "MoltenVK_lib.xcframework.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/MoltenVK_lib.xcframework.zip",
        checksum: "da7974885f41a290ec23fbaf05f74ab5d3538a1dfc0cec3a92c240683fbba865"
    ),
    "shaderc-android-arm64-v8a.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/shaderc-android-arm64-v8a.artifactbundle.zip",
        checksum: "7b1428fa7ae2480cabd5f391fdedf10528b926b9d497c5eb192357f8c21522b3"
    ),
    "shaderc-android-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/shaderc-android-x86_64.artifactbundle.zip",
        checksum: "b4fd78eb90e4b50d4b1aa6fbfff2d8c2d5442492a3e27b0021a0fbf7b339afac"
    ),
    "shaderc-linux-aarch64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/shaderc-linux-aarch64.artifactbundle.zip",
        checksum: "efa2bee536cc021078a28a35e773f44ad0e278bad3f1d297153e5c44ae267e5a"
    ),
    "shaderc-linux-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/shaderc-linux-x86_64.artifactbundle.zip",
        checksum: "95676982eb7ea400d0300e8cf1024a942c2af105888e24dafc354582b1eeab3d"
    ),
    "shaderc-wasm32.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/shaderc-wasm32.artifactbundle.zip",
        checksum: "d598c20159f1f7786ac2e63867bf3b324dea9dc04ffb8cc6f6192cbc837fd2ad"
    ),
    "shaderc-windows-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/shaderc-windows-x86_64.artifactbundle.zip",
        checksum: "791ef41094b66d62647c993af97029a1be615e770ca1d9070d88f4d97257979b"
    ),
    "shaderc.xcframework.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/shaderc.xcframework.zip",
        checksum: "5c3207785da05577cb7ec3d88670a2296c2a52c20794340da4972caddfefeda5"
    ),
    "spirv-cross-android-arm64-v8a.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/spirv-cross-android-arm64-v8a.artifactbundle.zip",
        checksum: "78e2bc3eacd1f8a27c62edd1ecdd6d508efc121e1d0ec3e63d00fda87cc811b1"
    ),
    "spirv-cross-android-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/spirv-cross-android-x86_64.artifactbundle.zip",
        checksum: "6a527cdad3bf74c0248d72b298ee4413cae641accc556d5c84c59094dd9d30ac"
    ),
    "spirv-cross-linux-aarch64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/spirv-cross-linux-aarch64.artifactbundle.zip",
        checksum: "3c6be78b2e9a4071158372b768dc89dc247fec892e5be450eb2db72d93bc15ff"
    ),
    "spirv-cross-linux-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/spirv-cross-linux-x86_64.artifactbundle.zip",
        checksum: "0eb25ca18af29c33b87b7b25997067a75ef2235d86bb1c755a37066e4d508f2d"
    ),
    "spirv-cross-wasm32.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/spirv-cross-wasm32.artifactbundle.zip",
        checksum: "8ddb121621805a9b17d0e1271857d2988c76148b651730464731b21df8b83024"
    ),
    "spirv-cross-windows-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/spirv-cross-windows-x86_64.artifactbundle.zip",
        checksum: "595ffe8825fb696059872f32140490575c00b8f622fba3e1400536201818de59"
    ),
    "spirv-cross.xcframework.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/spirv-cross.xcframework.zip",
        checksum: "60486374a87ff6485ce01fb9b6b66386c5f317c94c9cb04e8aa1b73b694daba4"
    ),
    "vulkan-loader-linux-aarch64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/vulkan-loader-linux-aarch64.artifactbundle.zip",
        checksum: "ec18307a66ad088288dc06146e395ad440f13aefd0c82cb63891eb61eb18099a"
    ),
    "vulkan-loader-linux-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/vulkan-loader-linux-x86_64.artifactbundle.zip",
        checksum: "12c4871c6a1f2e8170b01071c63def4590cc33a3c6bade11af7e99b7514ade6a"
    ),
    "vulkan-loader-windows-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/vulkan-loader-windows-x86_64.artifactbundle.zip",
        checksum: "4b29e4bd2a2e40716dbea6e09f57f2707550b6abf553ad16304358e5e285e66c"
    ),
    "wgpu_native-android-arm64-v8a.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/wgpu_native-android-arm64-v8a.artifactbundle.zip",
        checksum: "4eed831590678b98c9a0423adbabd5fa339a766fa9497d18ce2e7409dc72d13b"
    ),
    "wgpu_native-android-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/wgpu_native-android-x86_64.artifactbundle.zip",
        checksum: "2876ec4f27f2dd549e9cbc4bcd0a3940d0bae08d9933eeafdcab499977c94d8e"
    ),
    "wgpu_native-linux-aarch64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/wgpu_native-linux-aarch64.artifactbundle.zip",
        checksum: "a363b0627b452741044bdac03599adc700ae458f37a246097c97bdf5e917c20b"
    ),
    "wgpu_native-linux-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/wgpu_native-linux-x86_64.artifactbundle.zip",
        checksum: "bd4164d730bbf8e979d08b2ada811b7499bdba1377770210f3b864bcb4c35c69"
    ),
    "wgpu_native-windows-x86_64.artifactbundle.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/wgpu_native-windows-x86_64.artifactbundle.zip",
        checksum: "c6881bd92a16029341ddc262e557d0d62ddc9cf7aad1b4cd5c2b11569e33136f"
    ),
    "wgpu_native.xcframework.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/wgpu_native.xcframework.zip",
        checksum: "87eb04e38b54857e12705e020387ea8e2cd397b918c65e1a158b5968005242bb"
    ),
    "wgpu_native_framework.xcframework.zip": (
        url: "https://github.com/NucleantUI/NucleantVulkan/releases/download/0.0.2/wgpu_native_framework.xcframework.zip",
        checksum: "8814c717cde1c138524c6fcd5f689074dd40240e09bb57c2149d307677a2f977"
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

/// One library of Linux, Windows, Android or wasm as its own artifact bundle
/// (scripts/make_artifactbundle.py), named after the library, the platform
/// and the architecture — `wgpu_native-linux-x86_64.artifactbundle.zip` —
/// the way each library is its own xcframework zip on Apple's platforms. The
/// binary target has the library's name too. On Linux and Android the bundle
/// holds the shared library itself — SwiftPM copies it next to the product
/// and links it, so libwgpu_native.so stays the one copy ThorVG's library
/// links too, and an app ships every one of them: on Linux nothing but the
/// GPU driver comes from the machine. On Windows the bundle holds the DLL's
/// import library, which the product links, and the DLL itself, which SwiftPM
/// copies next to it (an `experimentalWindowsDLL` artifact) — the same
/// arrangement, the Windows way.
func prebuiltLibrary(_ library: String) -> Target {
    let platform: String
    switch platformTarget {
    case .wasi:
        platform = "wasm32"
    case .android:
        platform = "android-\(androidABI())"
    case .windows:
        // Native, as on Linux.
#if arch(arm64)
        platform = "windows-arm64"
#else
        platform = "windows-x86_64"
#endif
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
    case .windows:
        return [
            // vulkan-1.dll (the Khronos loader), wgpu_native.dll,
            // shaderc_shared.dll, spirv-cross-c-shared.dll — the same sources
            // as everywhere else, none of them the machine's, as on Linux.
            prebuiltLibrary("vulkan-loader"),
            prebuiltLibrary("wgpu_native"),
            prebuiltLibrary("shaderc"),
            prebuiltLibrary("spirv-cross"),
            // Vulkan-Headers 1.4.334, as everywhere, with VK_KHR_win32_surface.
            .target(
                name: "CVulkan",
                dependencies: ["vulkan-loader"],
                path: "Sources/CVulkanWindowsPrebuilt",
                sources: ["stub.c"],
                publicHeadersPath: "include"
            ),
            // shaderc's, spirv-cross's and wgpu-native's headers: the ones
            // Linux and Android build with, of the same refs.
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
    // Local mode takes the sibling only where it is checked out; a dev tree
    // without NucleantGeometry next to it still gets the GitHub release.
    let geometry = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("NucleantGeometry")
    if localDev && FileManager.default.fileExists(atPath: geometry.path) {
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
                // CWgpu is webgpu.h on the browser's WebGPU. Windows declares
                // its own as Linux does.
                deps.insert(.byName(name: "CWgpu", condition: .when(platforms: [.macOS, .linux, .android, .wasi, .windows])), at: 0)
                if platformTarget != .linux && platformTarget != .android && platformTarget != .wasi
                    && platformTarget != .windows {
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
