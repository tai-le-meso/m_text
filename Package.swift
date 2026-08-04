// swift-tools-version: 5.9
import PackageDescription

// No XCTest anywhere: it ships inside Xcode.app, and this project builds and tests
// with Command Line Tools alone. Tests are a plain executable over MTextTestKit.
let package = Package(
    name: "m_text",
    platforms: [.macOS(.v13)],
    products: [
        // MTextTests is deliberately not a product: products are built by a bare
        // `swift build`, which would drag the test code into `make bundle`.
        // `swift run MTextTests` works against the target directly.
        .executable(name: "m_text", targets: ["m_text"]),
    ],
    targets: [
        // Platform-free engine: buffers, selections, syntax, settings. No AppKit imports allowed.
        .target(name: "MTextCore"),
        // AppKit UI layer: windows, custom CoreText editor view.
        .target(name: "MTextUI", dependencies: ["MTextCore"]),
        // Thin executable: NSApplication bootstrap + menu.
        .executableTarget(name: "m_text", dependencies: ["MTextUI"]),
        // Assertion harness + runner, standing in for XCTest.
        .target(name: "MTextTestKit"),
        .executableTarget(name: "MTextTests", dependencies: ["MTextCore", "MTextTestKit"]),
    ]
)
