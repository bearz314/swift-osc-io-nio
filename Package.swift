// swift-tools-version: 6.0

import Foundation
import PackageDescription

let package = Package(
    name: "swift-osc-io-nio",
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .watchOS(.v6)],
    products: [
        .library(name: "SwiftOSCIO", targets: ["SwiftOSCIO"])
    ],
    dependencies: [
        .package(url: "https://github.com/orchetect/swift-osc-core", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.87.0") // lowest version that supports Swift 6.0
    ],
    targets: [
        .target(
            name: "SwiftOSCIO",
            dependencies: [
                .product(name: "SwiftOSCCore", package: "swift-osc-core"),
                .product(name: "SwiftOSCIOCore", package: "swift-osc-core"),
                .product(name: "NIO", package: "swift-nio")
            ],
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .testTarget(
            name: "SwiftOSCIOTests",
            dependencies: [
                "SwiftOSCIO"
            ]
        )
    ]
)

// MARK: - Utilities

func hasEnvironmentVariable(_ name: String) -> Bool {
    ProcessInfo.processInfo.environment[name] != nil
}

// MARK: - CI Pipeline

if hasEnvironmentVariable("GITHUB_ACTIONS") {
    for target in package.targets {
        if target.swiftSettings == nil { target.swiftSettings = [] }
        target.swiftSettings? += [.define("GITHUB_ACTIONS", .when(configuration: .debug))]
    }
}
