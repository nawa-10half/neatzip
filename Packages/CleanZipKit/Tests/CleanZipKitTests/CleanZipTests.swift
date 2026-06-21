import XCTest
import Foundation
@testable import CleanZipKit

final class CleanZipTests: XCTestCase {

    // MARK: - isJunk ユニット

    func testIsJunkRecognizesMacMetadata() {
        for junk in [".DS_Store", "._photo.jpg", "__MACOSX", ".AppleDouble",
                     ".Spotlight-V100", ".Trashes", ".fseventsd",
                     ".TemporaryItems", ".apdisk"] {
            XCTAssertTrue(CleanZip.isJunk(junk), "\(junk) はジャンク判定されるべき")
        }
    }

    func testIsJunkKeepsRealFiles() {
        for keep in ["photo.jpg", "notes.txt", "report.pdf", "data.csv", "DS_Store.txt"] {
            XCTAssertFalse(CleanZip.isJunk(keep), "\(keep) は通すべき")
        }
    }

    // MARK: - smart-store: 圧縮済み拡張子の判定ユニット

    func testIsPrecompressedRecognizesCompressedFormats() {
        for ext in ["jpg", "JPG", "Png", "mp4", "mov", "mp3", "zip", "gz",
                    "7z", "docx", "xlsx", "pptx", "epub", "apk", "woff2"] {
            XCTAssertTrue(CleanZip.isPrecompressed(ext), "\(ext) は圧縮済み判定されるべき")
        }
    }

    func testIsPrecompressedKeepsCompressibleFormats() {
        // pdf は意図的に除外（無圧縮ストリーム個体があるため）。txt/csv/bmp/tiff/wav 等も DEFLATE 対象。
        for ext in ["txt", "csv", "json", "xml", "html", "svg", "pdf",
                    "bmp", "tiff", "wav", "doc", "", "log"] {
            XCTAssertFalse(CleanZip.isPrecompressed(ext), "\(ext) は DEFLATE 対象（store しない）であるべき")
        }
    }

    // MARK: - smart-store: 圧縮済み拡張子は store・通常ファイルは DEFLATE される

    func testSmartStoreStoresPrecompressedExtensions() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cleanzip-smart-\(UUID().uuidString)")
        let project = root.appendingPathComponent("Project")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // どちらも「圧縮可能」な中身。拡張子だけが判定を分ける。
        let compressible = String(repeating: "NeatZip smart-store test payload. ", count: 4096)
        try compressible.write(to: project.appendingPathComponent("photo.jpg"), atomically: true, encoding: .utf8)
        try compressible.write(to: project.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        // 既定（smartStore = true）
        let out = root.appendingPathComponent("smart.zip")
        try CleanZip.make(items: [project], to: out)
        let methods = try zipMethods(out)
        XCTAssertEqual(methods["Project/photo.jpg"], "Stored",
                       "圧縮済み拡張子(.jpg)は store されるべき: \(methods)")
        XCTAssertEqual(methods["Project/notes.txt"]?.hasPrefix("Defl"), true,
                       "通常ファイル(.txt)は DEFLATE されるべき: \(methods)")

        // smartStore = false なら .jpg も DEFLATE される（= 機能が効いている裏取り）
        let outOff = root.appendingPathComponent("plainlevel.zip")
        try CleanZip.make(items: [project], to: outOff,
                          options: CleanZipOptions(smartStore: false))
        let methodsOff = try zipMethods(outOff)
        XCTAssertEqual(methodsOff["Project/photo.jpg"]?.hasPrefix("Defl"), true,
                       "smartStore=false では .jpg も DEFLATE されるべき: \(methodsOff)")
    }

    // MARK: - 進捗: バイト単調増加・最後に総量へ到達

    func testProgressReportsMonotonicAndReachesTotal() throws {
        let fm = FileManager.default
        let root = try makeFixtureTree()
        defer { try? fm.removeItem(at: root) }
        let out = root.appendingPathComponent("prog.zip")
        defer { try? fm.removeItem(at: out) }

        var snaps: [CleanZipProgress] = []
        try CleanZip.make(items: [root.appendingPathComponent("Project")], to: out,
                          progress: { snaps.append($0) })

        XCTAssertFalse(snaps.isEmpty, "進捗が1度も来ていない")
        // ジャンクを除いた実ファイルは2つ（keep.txt, sub/inner.txt）。総バイトは hello+inner=10。
        XCTAssertEqual(snaps.last?.totalFiles, 2)
        XCTAssertEqual(snaps.last?.totalBytes, 10)
        // 最後のスナップショットは完了状態（全件・全バイト・現在名は空）
        XCTAssertEqual(snaps.last?.completedFiles, 2)
        XCTAssertEqual(snaps.last?.completedBytes, snaps.last?.totalBytes)
        XCTAssertEqual(snaps.last?.currentName, "")
        XCTAssertEqual(snaps.last?.fraction, 1)
        // バイト・件数とも単調非減少
        for (a, b) in zip(snaps, snaps.dropFirst()) {
            XCTAssertLessThanOrEqual(a.completedBytes, b.completedBytes)
            XCTAssertLessThanOrEqual(a.completedFiles, b.completedFiles)
        }
    }

    // MARK: - キャンセル: 途中で止まり .cancelled を投げる

    func testCancellationStopsAndThrows() throws {
        let fm = FileManager.default
        let root = try makeFixtureTree()
        defer { try? fm.removeItem(at: root) }
        let out = root.appendingPathComponent("cancel.zip")
        defer { try? fm.removeItem(at: out) }

        var progressCalls = 0
        XCTAssertThrowsError(
            try CleanZip.make(items: [root.appendingPathComponent("Project")], to: out,
                              progress: { _ in progressCalls += 1 },
                              isCancelled: { progressCalls >= 1 })   // 1件進んだら以降キャンセル
        ) { error in
            guard case CleanZipError.cancelled = error else {
                return XCTFail("cancelled が投げられるべき: \(error)")
            }
        }
        // 2件あるうち2件目の手前で止まる（完了通知も来ない）
        XCTAssertEqual(progressCalls, 1, "1件処理後にキャンセルされるべき")
    }

    // MARK: - 統合: ジャンク混入ツリー → クリーン ZIP

    func testMakeExcludesJunk() throws {
        let fm = FileManager.default
        let root = try makeFixtureTree()
        defer { try? fm.removeItem(at: root) }

        let out = root.appendingPathComponent("out.zip")
        defer { try? fm.removeItem(at: out) }
        try CleanZip.make(items: [root.appendingPathComponent("Project")], to: out)

        let entries = try listZipEntries(out)
        // 入れたいものは入っている
        XCTAssertTrue(entries.contains("Project/keep.txt"), "実ファイル欠落: \(entries)")
        XCTAssertTrue(entries.contains("Project/sub/inner.txt"), "実ファイル欠落: \(entries)")
        // ジャンクは1つも無い（製品価値の核）
        for e in entries {
            XCTAssertFalse(e.contains(".DS_Store"),       "ジャンク混入: \(e)")
            XCTAssertFalse(e.contains("__MACOSX"),        "ジャンク混入: \(e)")
            XCTAssertFalse(e.contains(".Spotlight-V100"), "ジャンク混入: \(e)")
            XCTAssertFalse(e.contains("/._"),             "AppleDouble 混入: \(e)")
        }
    }

    // MARK: - 統合: パスワード(ZipCrypto) ラウンドトリップ

    func testPasswordZipCryptoRoundTrip() throws {
        let fm = FileManager.default
        let root = try makeFixtureTree()
        defer { try? fm.removeItem(at: root) }

        let out = root.appendingPathComponent("enc.zip")
        defer { try? fm.removeItem(at: out) }
        let opts = CleanZipOptions(password: "s3cret", encryption: .zipCrypto)
        try CleanZip.make(items: [root.appendingPathComponent("Project")], to: out, options: opts)

        // 正しいパスワードで展開でき、中身が一致する
        let dest = root.appendingPathComponent("extracted")
        let res = try run("/usr/bin/unzip", ["-P", "s3cret", "-o", out.path, "-d", dest.path])
        XCTAssertEqual(res.status, 0, "unzip 失敗: \(res.output)")
        let extracted = try String(contentsOf: dest.appendingPathComponent("Project/keep.txt"),
                                   encoding: .utf8)
        XCTAssertEqual(extracted, "hello")
    }

    // MARK: - 統合: 無パスワード（プレーン zip）

    func testNoPasswordPlain() throws {
        let fm = FileManager.default
        let root = try makeFixtureTree()
        defer { try? fm.removeItem(at: root) }

        let out = root.appendingPathComponent("plain.zip")
        defer { try? fm.removeItem(at: out) }
        try CleanZip.make(items: [root.appendingPathComponent("Project")], to: out)  // password 無し

        // パスワード無しで普通に展開できる（= 暗号化なし）
        let dest = root.appendingPathComponent("x-plain")
        let r = try run("/usr/bin/unzip", ["-o", out.path, "-d", dest.path])
        XCTAssertEqual(r.status, 0, "プレーン zip の展開失敗: \(r.output)")
        let extracted = try String(contentsOf: dest.appendingPathComponent("Project/keep.txt"),
                                   encoding: .utf8)
        XCTAssertEqual(extracted, "hello")
    }

    // MARK: - 統合: AES-256 ラウンドトリップ

    func testAES256RoundTrip() throws {
        let sevenZip = "/opt/homebrew/bin/7z"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: sevenZip),
                          "7z 未インストールのため AES 検証をスキップ")
        let fm = FileManager.default
        let root = try makeFixtureTree()
        defer { try? fm.removeItem(at: root) }

        let out = root.appendingPathComponent("aes.zip")
        defer { try? fm.removeItem(at: out) }
        let opts = CleanZipOptions(password: "aesPass", encryption: .aes256)
        try CleanZip.make(items: [root.appendingPathComponent("Project")], to: out, options: opts)

        // 7z（AES 対応）なら展開でき、内容一致
        let dest = root.appendingPathComponent("x-aes")
        let z = try run(sevenZip, ["x", "-paesPass", "-o\(dest.path)", out.path, "-y"])
        XCTAssertEqual(z.status, 0, "7z 展開失敗: \(z.output)")
        let extracted = try String(contentsOf: dest.appendingPathComponent("Project/keep.txt"),
                                   encoding: .utf8)
        XCTAssertEqual(extracted, "hello")

        // Info-ZIP unzip は AES 非対応 → 正しいパスワードでも失敗するはず（= 確かに AES-256）
        let dest2 = root.appendingPathComponent("x-unzip")
        let u = try run("/usr/bin/unzip", ["-P", "aesPass", "-o", out.path, "-d", dest2.path])
        XCTAssertNotEqual(u.status, 0, "unzip が AES を開けてしまった（AES になっていない疑い）")
    }

    // MARK: - 統合: 空ディレクトリ保持（Finder Compress 同等の構造再現）

    func testPreservesEmptyDirectories() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cleanzip-empty-\(UUID().uuidString)")
        let project = root.appendingPathComponent("Project")
        let emptyDir = project.appendingPathComponent("EmptyFolder")
        let nestedEmpty = project.appendingPathComponent("Outer/Inner")   // 入れ子の空
        let junkOnly = project.appendingPathComponent("JunkOnly")
        for d in [emptyDir, nestedEmpty, junkOnly] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try "hi".write(to: project.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: junkOnly.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }

        let out = root.appendingPathComponent("empty.zip")
        defer { try? fm.removeItem(at: out) }
        try CleanZip.make(items: [project], to: out)

        let entries = try listZipEntries(out)
        XCTAssertTrue(entries.contains("Project/keep.txt"), "実ファイル欠落: \(entries)")
        // 空フォルダがディレクトリエントリとして残る（末尾スラッシュは helper が除去）
        XCTAssertTrue(entries.contains("Project/EmptyFolder"), "空フォルダ欠落: \(entries)")
        // 入れ子の空は最深部が残る（Outer は Inner により暗黙再現される）
        XCTAssertTrue(entries.contains("Project/Outer/Inner"), "入れ子の空フォルダ欠落: \(entries)")
        // ジャンクのみのフォルダも（中身を除いた上で）空として残る。ジャンク本体は入らない。
        XCTAssertTrue(entries.contains("Project/JunkOnly"), "ジャンクのみフォルダ欠落: \(entries)")
        for e in entries {
            XCTAssertFalse(e.contains(".DS_Store"), "ジャンク混入: \(e)")
            XCTAssertFalse(e.contains("__MACOSX"), "ジャンク混入: \(e)")
        }
    }

    // MARK: - helpers

    /// Project/keep.txt, Project/sub/inner.txt の実ファイルと、各所に撒いたジャンクから成るツリー
    private func makeFixtureTree() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cleanzip-\(UUID().uuidString)")
        let project = root.appendingPathComponent("Project")
        let sub = project.appendingPathComponent("sub")
        let macosx = project.appendingPathComponent("__MACOSX")
        let spotlight = project.appendingPathComponent(".Spotlight-V100")
        for d in [sub, macosx, spotlight] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try "hello".write(to: project.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try "inner".write(to: sub.appendingPathComponent("inner.txt"), atomically: true, encoding: .utf8)
        // ── ジャンク（除外されるべき）──
        try "x".write(to: project.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        try "x".write(to: project.appendingPathComponent("._keep.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: sub.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        try "x".write(to: macosx.appendingPathComponent("decoy.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: spotlight.appendingPathComponent("store.db"), atomically: true, encoding: .utf8)
        return root
    }

    /// `unzip -Z1` でアーカイブ内エントリ名の一覧を得る（末尾スラッシュは除去）
    private func listZipEntries(_ zip: URL) throws -> [String] {
        let res = try run("/usr/bin/unzip", ["-Z1", zip.path])
        XCTAssertEqual(res.status, 0, "unzip -Z1 失敗: \(res.output)")
        return res.output.split(separator: "\n").map(String.init)
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
    }

    /// `unzip -v` から各エントリ名 → 圧縮メソッド（"Stored" / "Defl:N" 等）の対応を得る。
    /// 列は Length Method Size Cmpr Date Time CRC-32 Name の順（Name は末尾）。
    private func zipMethods(_ zip: URL) throws -> [String: String] {
        let res = try run("/usr/bin/unzip", ["-v", zip.path])
        XCTAssertEqual(res.status, 0, "unzip -v 失敗: \(res.output)")
        var map: [String: String] = [:]
        for line in res.output.split(separator: "\n") {
            let t = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard t.count >= 8, t[0].allSatisfy(\.isNumber) else { continue }  // ヘッダ/区切り行を除外
            map[t[7...].joined(separator: " ")] = t[1]
        }
        return map
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
