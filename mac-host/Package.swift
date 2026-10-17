// swift-tools-version:5.9
// Sill Desktop Host: an unofficial build of Sill's Mac host (github.com/Saffsanity/sill, Apache 2.0),
// with additions for the Sill Desktop viewers. See README.md and NOTICE.
import PackageDescription

let package = Package(
    name: "SillDesktopHost",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "StreamProtocol", targets: ["StreamProtocol"]),
        .executable(name: "SillHost", targets: ["SillHostCLI"]),
        .executable(name: "SillMenuBar", targets: ["SillMenuBar"]),
    ],
    targets: [
        .target(name: "StreamProtocol"),
        .target(name: "SillHostCore", dependencies: ["StreamProtocol"], path: "Sources/SillHost"),
        .executableTarget(name: "SillHostCLI", dependencies: ["SillHostCore", "StreamProtocol"]),
        .executableTarget(name: "SillMenuBar", dependencies: ["SillHostCore", "StreamProtocol"]),
    ]
)
