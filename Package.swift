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
        .binaryTarget(
            name: "Sparkle",
            path: "Vendor/Sparkle.xcframework"
        ),
        .executableTarget(
            name: "XiaomiRemoteBridgeMac",
            dependencies: [
                "Sparkle"
            ],
            path: "Sources/XiaomiRemoteBridgeMac",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .testTarget(
            name: "XiaomiRemoteBridgeMacTests",
            dependencies: ["XiaomiRemoteBridgeMac"],
            path: "Tests/XiaomiRemoteBridgeMacTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
