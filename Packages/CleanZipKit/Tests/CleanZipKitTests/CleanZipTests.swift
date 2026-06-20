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
