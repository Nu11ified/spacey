// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FocusWM",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "FocusWM", targets: ["FocusWM"])],
    targets: [
        .target(name: "WorkspaceCore"),
        .executableTarget(name: "FocusWM", dependencies: ["WorkspaceCore"]),
        .executableTarget(name: "FocusWMChecks", dependencies: ["WorkspaceCore"], path: "Tests/WorkspaceCoreTests")
    ]
)
