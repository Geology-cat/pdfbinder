// swift-tools-version: 5.10
// PDFBinder: 画像・PDFを結合して1つのPDFを作成するmacOSアプリ

import PackageDescription

let package = Package(
    name: "PDFBinder",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "PDFBinder",
            path: "Sources/PDFBinder"
        ),
        .testTarget(
            name: "PDFBinderTests",
            dependencies: ["PDFBinder"],
            path: "Tests/PDFBinderTests"
        )
    ]
)
