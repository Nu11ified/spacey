// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Spacey",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Spacey", targets: ["Spacey"])],
    targets: [
        .target(name: "WorkspaceCore"),
        .executableTarget(name: "Spacey", dependencies: ["WorkspaceCore"]),
        .executableTarget(name: "SpaceyChecks", dependencies: ["WorkspaceCore"], path: "Tests/SpaceyChecks")
    ]
)
