// swift-tools-version:5.9
import PackageDescription

// NeatZip のクリーン ZIP エンジン。SSZipArchive 依存はこのパッケージが所有し、
// 本体アプリ・テスト・将来のベンチ/バックエンド差し替え（DESIGN.md §5 #7）をこの境界内に閉じる。
let package = Package(
    name: "CleanZipKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CleanZipKit", targets: ["CleanZipKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ZipArchive/ZipArchive", from: "2.4.2"),
    ],
    targets: [
        .target(
            name: "CleanZipKit",
            dependencies: [.product(name: "ZipArchive", package: "ZipArchive")]
        ),
        .testTarget(
            name: "CleanZipKitTests",
            dependencies: ["CleanZipKit"]
        ),
    ]
)
