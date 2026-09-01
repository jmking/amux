// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "amux",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "amux",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/amux",
            resources: [.copy("Resources/agent-icons"), .copy("Resources/world")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
