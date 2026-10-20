// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ssh_check",
    platforms: [.macOS("15.4")],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio-extras", from: "1.24.0"),
    ],
    targets: [.executableTarget(name: "ssh_check", dependencies: [
        .product(name: "Citadel", package: "Citadel"),
        .product(name: "NIOSOCKS", package: "swift-nio-extras"),
    ])]
)
