// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SentryLogic", platforms: [.macOS(.v13)],
    products: [.library(name: "SentryLogic", targets: ["SentryLogic"])],
    targets: [
        .target(name: "SentryLogic", path: "Sentry/Logic"),
        .testTarget(name: "SentryLogicTests", dependencies: ["SentryLogic"], path: "Tests/SentryLogicTests"),
    ]
)
