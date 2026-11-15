// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "hocusfocus",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "hocusfocus", targets: ["hocusfocus"]),
        .executable(name: "HocusFocusApp", targets: ["HocusFocusApp"]),
    ],
    targets: [
        // The engine: finds the window under the mouse and focuses it.
        .target(name: "HocusFocusCore", path: "Sources/HocusFocusCore"),
        // Command line tool, for tests and diagnostics.
        .executableTarget(name: "hocusfocus", dependencies: ["HocusFocusCore"], path: "Sources/CLI"),
        // Menu bar app. build.sh wraps it in HocusFocus.app.
        .executableTarget(name: "HocusFocusApp", dependencies: ["HocusFocusCore"], path: "Sources/App"),
    ],
    swiftLanguageModes: [.v5]
)
