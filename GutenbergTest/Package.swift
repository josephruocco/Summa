// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GutenbergTest",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "gutenberg-test",
            path: "Sources",
            resources: [.copy("common_words_en_20k.txt")]
        )
    ]
)
