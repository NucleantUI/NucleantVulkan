// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let localDev = false

func getPlatformTarget() -> PackageDescription.Platform {
#if ANDROID_BUILD
    return .android
#elseif LINUX_BUILD
    return .linux
#else
    return .macOS
#endif
}

let platformTarget = getPlatformTarget()


func getDependencies() -> [Package.Dependency] {
    var deps = [Package.Dependency]()
    if localDev {
        deps.append(.package(path: "../SulphurGeometry"))
    } else {
        deps.append(.package(url: "https://github.com/NucleantUI/SulphurGeometry", branch: "init_upload"))
    }
    return deps
}



func vulkanTargets() -> [Target] {
    var targets: [Target] = []
    
    switch platformTarget {
    case let p where p == .linux:
        // System Vulkan loader via pkg-config.
        // WSI backends auto-detected from installed dev headers in CVulkanLinux/shim.h.
        // Requires: apt install libvulkan-dev
        targets.append(
            .systemLibrary(
                name: "CVulkan",
                path: "Sources/CVulkanLinux",
                pkgConfig: "vulkan",
                providers: [
                    .apt(["libvulkan-dev"])
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
        targets.append(
            .binaryTarget(
                name: "MoltenVK",
                path: "Dependencies/MoltenVK.xcframework"
            )
        )
        
        targets.append(
            .target(
                name: "CVulkan",
                dependencies: [
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
            path: "Dependencies/wgpu_native.xcframework"
        )
    )
    targets.append(
        .binaryTarget(
            name: "CWgpuFW",
            path: "Dependencies/wgpu_native_framework.xcframework"
        )
    )
    targets.append(contentsOf: [
        .binaryTarget(
             name: "shaderc",
             path: "Dependencies/shaderc.xcframework"
         ),
         
         // spirv-cross xcframework (SPIR-V -> MSL/HLSL cross-compiler)
         .binaryTarget(
             name: "spirv-cross",
             path: "Dependencies/spirv-cross.xcframework"
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
            dependencies: [
                // macOS links the bare dylib (module CWgpu); iOS links the
                // framework (module wgpu_native) — see the binary targets above.
                // WgpuContext / VulkanRenderEngine import the right one per
                // platform. SPM links + embeds whichever applies.
                .byName(name: "CWgpu",   condition: .when(platforms: [.macOS])),
                .byName(name: "CWgpuFW", condition: .when(platforms: [.iOS])),
                "VulkanCore",
                "NucleantShader"
            ]
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
    [
        .library(
            name: "NucleantVulkan",
            targets: ["NucleantVulkan", "CVulkan"]
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
