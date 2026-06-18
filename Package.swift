// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MemorySentry",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "MemorySentry",
            targets: ["MemorySentry"]
        )
    ],
    targets: [
        .target(
            name: "MemorySentry",
            path: "Sources/MemorySentry"
        ),
        .testTarget(
            name: "MemorySentryTests",
            dependencies: ["MemorySentry"],
            path: "Tests/MemorySentryTests"
        )
    ]
)
