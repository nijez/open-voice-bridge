// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenVoiceBridge",
    platforms: [.macOS(.v11)],
    products: [
        .executable(
            name: "XiaomiRemoteBridgeMac",
            targets: ["XiaomiRemoteBridgeMac"]
        )
    ],
    targets: [
        .executableTarget(
            name: "XiaomiRemoteBridgeMac",
            path: "Sources/XiaomiRemoteBridgeMac"
        ),
        .testTarget(
            name: "XiaomiRemoteBridgeMacTests",
            dependencies: ["XiaomiRemoteBridgeMac"],
            path: "Tests/XiaomiRemoteBridgeMacTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
