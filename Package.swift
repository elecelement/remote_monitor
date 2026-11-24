// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GPUWorkbench",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "GPUWorkbench", targets: ["GPUWorkbench"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git",
                 revision: "5d14406844143538cd8f8851d2d8a67c1fe443e5")
    ],
    targets: [
        .target(name: "WorkbenchCore", resources: [.copy("Resources/remote.py")]),
        .executableTarget(name: "GPUWorkbench", dependencies: [
            "WorkbenchCore", .product(name: "SwiftTerm", package: "SwiftTerm")
        ]),
        .testTarget(name: "WorkbenchCoreTests", dependencies: [
            "WorkbenchCore", .product(name: "SwiftTerm", package: "SwiftTerm")
        ]),
        .testTarget(name: "GPUWorkbenchTests", dependencies: [
            "GPUWorkbench", .product(name: "SwiftTerm", package: "SwiftTerm")
        ])
    ]
)
