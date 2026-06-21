import Foundation
import CleanZipKit

// 新エンジン（libdeflate 並列 + minizip-ng raw write）の性能チェックポイント（DESIGN.md §5 #11）。
//   swift run --package-path Packages/CleanZipKit -c release CleanZipBench

func timeIt(_ body: () throws -> Void) rethrows -> Double {
    let s = DispatchTime.now()
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - s.uptimeNanoseconds) / 1_000_000_000
}
func r(_ x: Double, _ p: Int) -> String { String(format: "%.\(p)f", x) }
func mb(_ b: Int64) -> Double { Double(b) / 1_000_000 }

let fm = FileManager.default

func fileSize(_ u: URL) -> Int64 { Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
func dirInfo(_ u: URL) -> (bytes: Int64, files: Int) {
    var b: Int64 = 0, n = 0
    if let e = fm.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
        for case let f as URL in e where ((try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false) {
            b += fileSize(f); n += 1
        }
    }
    return (b, n)
}

let unit = Data("The quick brown fox jumps over the lazy dog. クリーンZIP 0123456789\n".utf8)
func writeCompressible(_ u: URL, bytes: Int) {
    var d = Data(); d.reserveCapacity(bytes + unit.count)
    while d.count < bytes { d.append(unit) }
    try! d.write(to: u)
}
let urandom = FileHandle(forReadingAtPath: "/dev/urandom")!
func writeRandom(_ u: URL, bytes: Int) { try! urandom.readData(ofLength: bytes).write(to: u) }

let root = fm.temporaryDirectory.appendingPathComponent("neatzip-bench-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

// ---- フィクスチャ生成 ----
func buildManySmall() -> URL {
    let d = root.appendingPathComponent("many-small")
    try! fm.createDirectory(at: d, withIntermediateDirectories: true)
    for i in 0..<3000 { writeCompressible(d.appendingPathComponent("f\(i).txt"), bytes: 1024) }
    return d
}
func buildLargeText() -> URL {
    let d = root.appendingPathComponent("large-text")
    try! fm.createDirectory(at: d, withIntermediateDirectories: true)
    for i in 0..<5 { writeCompressible(d.appendingPathComponent("big\(i).txt"), bytes: 10*1024*1024) }
    return d
}
func buildIncompressible() -> URL {
    let d = root.appendingPathComponent("incompressible")
    try! fm.createDirectory(at: d, withIntermediateDirectories: true)
    for i in 0..<5 { writeRandom(d.appendingPathComponent("rnd\(i).bin"), bytes: 10*1024*1024) }
    return d
}
// 圧縮済み拡張子（.mp4）を持つ＝実質ランダムな中身。smart-store が自動で store にすべき対象。
func buildPrecompressed() -> URL {
    let d = root.appendingPathComponent("precompressed")
    try! fm.createDirectory(at: d, withIntermediateDirectories: true)
    for i in 0..<5 { writeRandom(d.appendingPathComponent("clip\(i).mp4"), bytes: 10*1024*1024) }
    return d
}

// ---- 1ケース実行（best of 2）----
func run(label: String, src: URL, info: (bytes: Int64, files: Int), options: CleanZipOptions) {
    let out = root.appendingPathComponent("\(label).zip")
    var best = Double.greatestFiniteMagnitude
    for _ in 0..<2 {
        try? fm.removeItem(at: out)
        best = min(best, try! timeIt { try CleanZip.make(items: [src], to: out, options: options) })
    }
    let outB = fileSize(out)
    let thr = mb(info.bytes) / best
    let ratio = info.bytes > 0 ? Double(outB) / Double(info.bytes) * 100 : 0
    let name = label.padding(toLength: 22, withPad: " ", startingAt: 0)
    print("\(name) in=\(r(mb(info.bytes),1))MB files=\(info.files)  time=\(r(best,3))s  \(r(thr,1)) MB/s  out=\(r(mb(outB),1))MB (\(Int(ratio.rounded()))%)")
}

print("=== NeatZip / libdeflate並列 + minizip-ng raw write — \(ProcessInfo.processInfo.processorCount) cores ===")
print("各行 best-of-2。level -1=default, 0=store。AES-256 はパスワード付き。\n")

let small = buildManySmall();        let smallInfo = dirInfo(small)
let large = buildLargeText();        let largeInfo = dirInfo(large)
let rnd   = buildIncompressible();   let rndInfo = dirInfo(rnd)
let pre   = buildPrecompressed();    let preInfo = dirInfo(pre)

// 既存ケースは smart-store の影響を受けない拡張子（.txt / .bin）なので明示 off で基準値を保つ。
run(label: "many-small default", src: small, info: smallInfo, options: CleanZipOptions(compressionLevel: -1, smartStore: false))
run(label: "large-text default",  src: large, info: largeInfo, options: CleanZipOptions(compressionLevel: -1, smartStore: false))
run(label: "large-text AES-256",  src: large, info: largeInfo, options: CleanZipOptions(password: "p", encryption: .aes256, compressionLevel: -1, smartStore: false))
run(label: "incompress default",  src: rnd, info: rndInfo, options: CleanZipOptions(compressionLevel: -1, smartStore: false))
run(label: "incompress store(0)", src: rnd, info: rndInfo, options: CleanZipOptions(compressionLevel: 0))
// smart-store: 圧縮済み拡張子(.mp4)を default で投げる。on は自動 store・off は無駄に DEFLATE。
run(label: "precompressed smart-off", src: pre, info: preInfo, options: CleanZipOptions(compressionLevel: -1, smartStore: false))
run(label: "precompressed smart-on",  src: pre, info: preInfo, options: CleanZipOptions(compressionLevel: -1, smartStore: true))
print("\ndone")
