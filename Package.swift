// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "imgDirView",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "imgDirView",
            path: "Sources/imgDirView"
        )
    ]
)
