// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OpenMime",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenMime", targets: ["OpenMime"]),
    ],
    targets: [
        .executableTarget(
            name: "OpenMime",
            path: "Sources/OpenMime",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("WebKit"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "OpenMimeTests",
            dependencies: ["OpenMime"],
            path: "Tests/OpenMimeTests"
        ),
    ]
)
