// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TranscribeKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TranscribeCore", targets: ["TranscribeCore"]),
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .library(name: "Transcriber", targets: ["Transcriber"]),
        .library(name: "SongMatcher", targets: ["SongMatcher"]),
        .library(name: "ScriptureDetector", targets: ["ScriptureDetector"]),
        .library(name: "SectionClassifier", targets: ["SectionClassifier"]),
        .library(name: "Exporter", targets: ["Exporter"]),
    ],
    targets: [
        .target(name: "TranscribeCore"),
        .target(name: "AudioCapture"),
        .target(name: "Transcriber", dependencies: ["AudioCapture"]),
        .target(name: "SongMatcher", dependencies: ["TranscribeCore"]),
        .target(name: "ScriptureDetector", dependencies: ["TranscribeCore"]),
        .target(name: "SectionClassifier", dependencies: ["TranscribeCore"]),
        .target(name: "Exporter"),
        .executableTarget(name: "TranscribeSmoke", dependencies: ["AudioCapture", "Transcriber", "ScriptureDetector", "SongMatcher", "TranscribeCore", "SectionClassifier"]),
        .testTarget(name: "ScriptureDetectorTests", dependencies: ["ScriptureDetector", "TranscribeCore"]),
        .testTarget(name: "SongMatcherTests", dependencies: ["SongMatcher"]),
        .testTarget(name: "ExporterTests", dependencies: ["Exporter"]),
        .testTarget(name: "SectionClassifierTests", dependencies: ["SectionClassifier"]),
    ]
)
