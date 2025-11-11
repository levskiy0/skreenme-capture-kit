// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SkreenmeCaptureKIT",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SkreenmeCaptureKIT", targets: ["SkreenmeCaptureKIT"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "SkreenmeCaptureKIT",
            path: "Sources",
            resources: []
        )
    ]
)
