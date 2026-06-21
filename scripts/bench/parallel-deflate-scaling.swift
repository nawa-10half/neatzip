// 並列 deflate のスケーリング上限を測る（NeatZip 速度差別化の根拠データ / DESIGN §5）。
// システムの Compression framework(zlib=deflate)を使い、並列度 width を変えて
// スループットとスピードアップを出す。「並列化でどこまで速くなるか」の上限の目安。
//
//   実行: swift scripts/bench/parallel-deflate-scaling.swift
//
// 参考実測（2026-06-21, M系 10コア, 160MB 中圧縮）: width=1→48MB/s, width=10→314MB/s（6.4x）。圧縮率は不変。
import Foundation
import Compression
import Dispatch

let cores = ProcessInfo.processInfo.processorCount

// --- 中圧縮データ（base64(urandom) ≒ 規則性のあるテキスト、deflate がそこそこ働く代表）---
func midData(_ bytes: Int) -> Data {
    let fh = FileHandle(forReadingAtPath: "/dev/urandom")!
    return fh.readData(ofLength: bytes * 3 / 4).base64EncodedData()
}

let fileCount = 40
let fileBytes = 4 * 1024 * 1024
print("=== 並列 deflate スケーリング（\(cores) cores）===")
print("データ: \(fileCount) ファイル × \(fileBytes / (1024*1024))MB = \(fileCount * fileBytes / (1024*1024))MB（中圧縮 base64(urandom)）\n")
let datas = (0..<fileCount).map { _ in midData(fileBytes) }
let totalBytes = datas.reduce(0) { $0 + $1.count }

// --- 1ファイル deflate（zlib）---
func deflate(_ input: Data) -> Int {
    let dstSize = input.count + 4096
    let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
    defer { dst.deallocate() }
    return input.withUnsafeBytes { src in
        compression_encode_buffer(dst, dstSize,
            src.bindMemory(to: UInt8.self).baseAddress!, input.count,
            nil, COMPRESSION_ZLIB)
    }
}

// --- 並列度 width で全ファイルを deflate、所要秒を返す（best-of-2）---
func run(width: Int) -> (sec: Double, outBytes: Int) {
    var best = Double.greatestFiniteMagnitude
    var out = 0
    for _ in 0..<2 {
        let sem = DispatchSemaphore(value: width)
        let group = DispatchGroup()
        let q = DispatchQueue(label: "w", attributes: .concurrent)
        let lock = NSLock()
        var sum = 0
        let start = DispatchTime.now()
        for d in datas {
            sem.wait(); group.enter()
            q.async {
                let n = deflate(d)
                lock.lock(); sum += n; lock.unlock()
                sem.signal(); group.leave()
            }
        }
        group.wait()
        let sec = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        best = min(best, sec); out = sum
    }
    return (best, out)
}

let base = run(width: 1).sec
print("width        sec         MB/s    speedup    ratio")
for w in [1, 2, 4, 8, cores] where w <= cores {
    let (sec, out) = run(width: w)
    let mbps = Double(totalBytes) / 1e6 / sec
    let speedup = base / sec
    let ratio = Double(out) / Double(totalBytes) * 100
    print(String(format: "%-6d %10.3f %12.1f %9.2fx %7.0f%%", w, sec, mbps, speedup, ratio))
}
print("\n※ speedup は width=1 比。理想は width に比例（10コアで ~10x）だが、メモリ帯域・スケジューリングで頭打ちになる。")
