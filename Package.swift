// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "macdelete",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "delete", targets: ["DeleteTool"]),
    ],
    targets: [
        .target(name: "DeleteCore"),
        .executableTarget(name: "DeleteTool", dependencies: ["DeleteCore"]),
        .testTarget(name: "DeleteCoreTests", dependencies: ["DeleteCore"]),
    ]
)
