// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AsyncDevStudioMacOS",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AsyncDevStudio", targets: ["AsyncDevStudio"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.5.1"),
        // SwiftTerm's command-line demo dependency must also support Swift 5.10.
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.5.0")
    ],
    targets: [
        .target(name: "StudioKernel"),
        .target(name: "StudioPlatform"),
        .target(name: "StudioPresentation", dependencies: ["StudioKernel"]),
        .target(name: "BrowserPlugin", dependencies: ["StudioKernel"]),
        .target(name: "TeamsPlugin", dependencies: ["StudioKernel", "BrowserPlugin"], resources: [.process("Resources")]),
        .target(name: "EditorPlugin", dependencies: ["StudioKernel"]),
        .target(name: "ImagePlugin", dependencies: ["StudioKernel"]),
        .target(name: "PTYSupport"),
        .target(name: "TerminalPlugin", dependencies: ["StudioKernel", "PTYSupport", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .target(name: "ClaudePlugin", dependencies: ["StudioKernel", "TerminalPlugin"]),
        .target(name: "CodexPlugin", dependencies: ["StudioKernel", "TerminalPlugin"]),
        .executableTarget(name: "AsyncDevStudio", dependencies: ["StudioKernel", "StudioPresentation", "TerminalPlugin", "BrowserPlugin", "EditorPlugin", "StudioPlatform", "TeamsPlugin", "ClaudePlugin", "CodexPlugin", "ImagePlugin"]),
        .executableTarget(name: "StudioTests", dependencies: ["StudioKernel", "StudioPresentation", "TerminalPlugin", "BrowserPlugin", "EditorPlugin", "StudioPlatform", "TeamsPlugin", "ClaudePlugin", "CodexPlugin", "ImagePlugin"], path: "Tests")
    ]
)
