// swift-tools-version: 5.10
//
// QDVC GTD EML for macOS — a native SwiftUI app for working a Getting Things
// Done workflow over .eml files. It opens the same workspace folder as the
// qdvc-gtd-eml command-line tool (six numbered folders plus metadata.csv, see
// docs/FILE_FORMAT.md) and performs the same workflow actions, byte for byte,
// but neither needs the other.
//
// Build:   swift build            (or open this folder in Xcode)
// Test:    swift test
// Bundle:  scripts/build-app.sh   (ad-hoc signed .app, no Apple account needed)

import PackageDescription

var products: [Product] = [
    .library(name: "GTDCore", targets: ["GTDCore"]),
]
var targets: [Target] = [
    // Pure model layer: Foundation (+ Yams) only, no AppKit/SwiftUI,
    // unit-testable.
    .target(
        name: "GTDCore",
        dependencies: [.product(name: "Yams", package: "Yams")]
    ),
    .testTarget(
        name: "GTDCoreTests",
        dependencies: ["GTDCore"],
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
// The SwiftUI/AppKit front-end. Declared on macOS only, so the core and its
// tests also build with a Linux Swift toolchain (docs/MAINTENANCE.md).
products.insert(.executable(name: "QDVCGTDEML", targets: ["QDVCGTDEML"]), at: 0)
targets.insert(.executableTarget(name: "QDVCGTDEML", dependencies: ["GTDCore"]), at: 1)
#endif

let package = Package(
    name: "QDVCGTDEML",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: targets
)
