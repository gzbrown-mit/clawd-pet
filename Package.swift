// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClawdPet",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClawdPet",
            path: "Sources/ClawdPet"
        )
    ],
    swiftLanguageVersions: [.v5]
)
