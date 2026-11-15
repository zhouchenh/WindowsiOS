// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "gmrcli",
    platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/stossy11/StosSign", branch: "main")],
    targets: [
        .executableTarget(
            name: "gmrcli",
            dependencies: [
                .product(name: "StosSign_API", package: "StosSign"),
                .product(name: "StosSign_Auth", package: "StosSign"),
                .product(name: "StosSign_Common", package: "StosSign"),
            ]
        )
    ]
)
