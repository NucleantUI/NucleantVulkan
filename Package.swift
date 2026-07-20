// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let localDev = true

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
    targets.append(
        .systemLibrary(
            name: "CWgpu",
            path: "Sources/CWgpu"
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
                "CWgpu",
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
        .iOS(.v15),
        .macOS(.v14)
    ],
    products: getProducts(),
    dependencies: getDependencies(),
    targets: getTargets()
)
