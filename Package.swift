// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClashRemote",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ClashRemote",
            path: "Sources/ClashRemote"
        )
    ]
)
