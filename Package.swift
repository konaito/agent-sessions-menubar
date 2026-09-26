// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentSessionsMenubar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AgentSessionsMenubar", path: "Sources/AgentSessionsMenubar")
    ]
)
