// swift-tools-version:5.9
import PackageDescription

// NeatZip のクリーン ZIP エンジン。速度差別化のため SSZipArchive(zlib) を捨て、
// vendored の libdeflate(1.25) + パッチ済み minizip-ng(4.2.1) を直接叩く（DESIGN.md §5 #11）。
// C ライブラリは SwiftPM の C ターゲットとして同梱（バイナリ target を避け swift test/Xcode 両対応）。
let package = Package(
    name: "CleanZipKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CleanZipKit", targets: ["CleanZipKit"]),
    ],
    targets: [
        // libdeflate 1.25（無改変）。raw deflate 圧縮 + crc32。
        .target(
            name: "Clibdeflate",
            path: "Sources/Clibdeflate",
            publicHeadersPath: "include"
        ),
        // minizip-ng 4.2.1 + NeatZip パッチ（raw+AES 両立 / CTRバルク化 / 並列導出鍵注入）。
        // 暗号は Apple CommonCrypto(mz_crypt_apple.c)、zlib は system。
        .target(
            name: "Cminizip",
            path: "Sources/Cminizip",
            publicHeadersPath: "include",
            cSettings: [
                // system zlib(classic) を使う。未定義だと zlib-ng API を要求して zlib-ng.h を探す。
                .define("ZLIB_COMPAT"),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "CleanZipKit",
            dependencies: ["Clibdeflate", "Cminizip"]
        ),
        .testTarget(
            name: "CleanZipKitTests",
            dependencies: ["CleanZipKit"]
        ),
        .executableTarget(
            name: "CleanZipBench",
            dependencies: ["CleanZipKit"]
        ),
    ]
)
