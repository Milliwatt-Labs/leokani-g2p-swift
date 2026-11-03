// swift-tools-version: 5.9
// Leokani G2P for Swift: English text to Kokoro-style phonemes. Code MIT; weights, lexicon and goldens CC BY 4.0.
import PackageDescription

let package = Package(
    name: "LeokaniG2P",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "LeokaniG2P", targets: ["LeokaniG2P"]),
        .executable(name: "leokani-g2p", targets: ["LeokaniG2PCLI"]),
    ],
    targets: [
        .target(
            name: "LeokaniG2P",
            resources: [.copy("Resources/model")]
        ),
        .executableTarget(name: "LeokaniG2PCLI", dependencies: ["LeokaniG2P"]),
        .testTarget(
            name: "LeokaniG2PTests",
            dependencies: ["LeokaniG2P"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
