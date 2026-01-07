// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CodexSkillManager",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.1"),
    ],
    targets: [
        .executableTarget(
            name: "CodexSkillManager",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/CodexSkillManager")
    ]
)
