// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebVideoCompressor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CompressorCore", targets: ["CompressorCore"]),
        .executable(name: "WebVideoCompressor", targets: ["WebVideoCompressor"]),
    ],
    targets: [
        .target(name: "CompressorCore"),
        .executableTarget(name: "WebVideoCompressor", dependencies: ["CompressorCore"]),
        .testTarget(name: "CompressorCoreTests", dependencies: ["CompressorCore"]),
    ]
)
