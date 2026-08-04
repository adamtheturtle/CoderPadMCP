// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoderPadMCP",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "CoderPadMCP", targets: ["CoderPadMCP"]),
        .library(name: "CoderPadToolCore", targets: ["CoderPadToolCore"]),
        .executable(name: "coderpad-mcp", targets: ["coderpad-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/adamtheturtle/MCPKit.git", from: "0.3.0"),
        .package(url: "https://github.com/adamtheturtle/CoderPadKit.git", from: "0.5.9"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.4.3"),
    ],
    targets: [
        .target(name: "CoderPadToolCore"),
        .target(
            name: "CoderPadMCP",
            dependencies: [
                "CoderPadToolCore",
                .product(name: "CoderPadKit", package: "CoderPadKit"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "MCPKit", package: "MCPKit"),
            ],
        ),
        .executableTarget(
            name: "coderpad-mcp",
            dependencies: [
                "CoderPadMCP",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "MCPKit", package: "MCPKit"),
            ],
        ),
        .testTarget(name: "CoderPadMCPTests", dependencies: ["CoderPadMCP"]),
        .testTarget(name: "CoderPadToolCoreTests", dependencies: ["CoderPadToolCore"]),
    ],
)
