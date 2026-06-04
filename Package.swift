// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Plans",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "Plans",
            path: "Sources/Plans"
        )
    ]
)
