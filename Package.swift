// swift-tools-version: 6.0
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "KindleDrive", platforms: [.macOS(.v14)],
    products: [.executable(name: "KindleDrive", targets: ["KindleDrive"])],
    targets: [
        .target(name: "CMTP", cSettings: [.unsafeFlags(["-I\(root)/Vendor/installed/include"])],
                linkerSettings: [.unsafeFlags(["-L\(root)/Vendor/installed/lib", "-lmtp", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", "\(root)/Vendor/installed/lib"])]),
        .executableTarget(name: "KindleDrive", dependencies: ["CMTP"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "KindleDriveTests", dependencies: ["KindleDrive"], path: "Tests")
    ])
