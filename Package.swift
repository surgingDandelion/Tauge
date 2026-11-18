// swift-tools-version: 5.9
import PackageDescription

// ShellX — a local-first macOS SSH/SFTP client.
//
// Built with SwiftPM only (Command Line Tools toolchain): XCTest/swift-testing
// are not shipped by the CLT SDK, so the self-check suite is an executable
// target run with "swift run ShellXChecks".
let package = Package(
    name: "ShellX",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ShellX", targets: ["ShellXApp"]),
        .library(name: "ShellXKit", targets: ["ShellXKit"]),
        .executable(name: "ShellXChecks", targets: ["ShellXChecks"]),
    ],
    dependencies: [
        // Vendored fork: adds RFC 8332 RSA (rsa-sha2-256/rsa-sha2-512) user authentication,
        // which upstream swift-nio-ssh does not implement.
        .package(path: "Vendor/swift-nio-ssh"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(path: "Vendor/SwiftTerm"),
    ],
    targets: [
        .target(
            name: "ShellXKit",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "ShellXApp",
            dependencies: [
                "ShellXKit",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/ShellXApp",
            resources: [.copy("Assets")]
        ),
        .executableTarget(
            name: "ShellXChecks",
            dependencies: [
                "ShellXKit",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/ShellXChecks"
        ),
    ]
)