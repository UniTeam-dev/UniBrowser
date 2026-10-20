// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ssh_check",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/orlandos-nl/Citadel", exact: "0.12.1")],
    targets: [.executableTarget(name: "ssh_check", dependencies: [.product(name: "Citadel", package: "Citadel")])]
)
