// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TofuPOSCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "TofuPOSCore", targets: ["TofuPOSCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", path: "ios/CSQLite"),
        .target(name: "TofuPOSCore", dependencies: ["CSQLite"], path: "ios/Core"),
        .testTarget(name: "TofuPOSCoreTests", dependencies: ["TofuPOSCore"], path: "ios/Tests")
    ]
)
