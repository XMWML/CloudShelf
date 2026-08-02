// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CloudShelf",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CloudShelfCore", targets: ["CloudShelfCore"])
    ],
    targets: [
        .target(
            name: "CloudShelfCore",
            path: "Sources/CloudShelf",
            exclude: ["App", "AppKit"],
            sources: ["Domain", "Infrastructure"]
        ),
        .executableTarget(
            name: "CloudShelf",
            dependencies: ["CloudShelfCore"],
            path: "Sources/CloudShelf",
            exclude: ["Domain", "Infrastructure"],
            sources: ["App/LocalNetworkAccessRequester.swift", "App/WorkspaceStore.swift", "AppKit"]
        ),
        .executableTarget(
            name: "CloudShelfSmoke",
            dependencies: ["CloudShelfCore"],
            path: "Sources/CloudShelfSmoke"
        )
    ]
)
