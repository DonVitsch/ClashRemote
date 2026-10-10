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
            path: "Sources/ClashRemote",
            exclude: [
                "Resources/node-failover.sh",
                "Resources/install-on-device.sh",
                "Resources/ufi-failover-plugin.js"
            ],
            resources: [
                .copy("Resources/cr-failover.html"),
                .copy("Resources/CatLogo.png"),
                .copy("Resources/CatNetworkIllustration.png")
            ]
        ),
        .testTarget(
            name: "ClashRemoteTests",
            dependencies: ["ClashRemote"]
        )
    ]
)
