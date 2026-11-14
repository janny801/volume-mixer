// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "VolumeMixer",
    platforms: [.macOS("14.4")],
    products: [.executable(name: "VolumeMixer", targets: ["VolumeMixer"])],
    targets: [
        .target(name: "AudioBridge", publicHeadersPath: "include", linkerSettings: [
            .linkedFramework("CoreAudio"), .linkedFramework("AppKit")
        ]),
        .executableTarget(name: "VolumeMixer", dependencies: ["AudioBridge"],
                          swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
