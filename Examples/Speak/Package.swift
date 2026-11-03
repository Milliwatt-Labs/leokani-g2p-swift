// swift-tools-version: 5.9
// An example app using Leokani G2P: phonemes for a few lines, with custom pronunciations from names.tsv.
import PackageDescription

let package = Package(
    name: "Speak",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "Speak",
            dependencies: [.product(name: "LeokaniG2P", package: "LeokaniG2P")],
            resources: [.copy("names.tsv")]
        ),
    ]
)
