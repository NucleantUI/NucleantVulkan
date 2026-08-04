// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let localDev = true

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

let platformTarget = getPlatformTarget()

// Set by pyswiftkit-builder for a wheel build. It distinguishes the two macOS
// modes — `uv run` against a wheel, versus the Xcode app that embeds this
// package — which differ in whether a dependency should be a bare dylib or a
// framework bundle. See the MoltenVK binary targets below.
let PIP_MODE = ProcessInfo.processInfo.environment["PIP_MODE"] == "1"


func getDependencies() -> [Package.Dependency] {
    var deps = [Package.Dependency]()
    if localDev {
        deps.append(.package(path: "../SulphurGeometry"))
    } else {
        deps.append(.package(url: "https://github.com/NucleantUI/SulphurGeometry", branch: "master"))
    }
    return deps
}



func vulkanTargets() -> [Target] {
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
                .product(name: "SulphurGeometry", package: "SulphurGeometry")
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
                    // .android included: the Android branch of vulkanTargets()
                    // declares its own CWgpu (vendored libwgpu_native.so),
                    // and without it here the target exists but never links.
                    .byName(name: "CWgpu", condition: .when(platforms: [.macOS, .linux, .android])),
                    "VulkanCore",
                    "NucleantShader"
                ]
                if platformTarget != .linux && platformTarget != .android {
                    deps.append(.byName(name: "CWgpuFW", condition: .when(platforms: [.iOS])))
                }
                return deps
            }()
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
