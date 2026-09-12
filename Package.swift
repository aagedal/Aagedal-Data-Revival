// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DataRevival",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DataRevival", targets: ["DataRevival"])],
    targets: [
        .executableTarget(name: "DataRevival"),
        .testTarget(name: "DataRevivalTests", dependencies: ["DataRevival"])
    ]
)
