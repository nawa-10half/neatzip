import Foundation
import ZipArchive   // SSZipArchive — SwiftPM: https://github.com/ZipArchive/ZipArchive

public enum ZipEncryption {
    case none
    case zipCrypto   // 互換重視: Finder ダブルクリック / Windows で開ける（弱い）
    case aes256      // 強力: 受信側に Keka / The Unarchiver / 7-Zip が必要
}

public struct CleanZipOptions {
    public var password: String?
    public var encryption: ZipEncryption
    public var compressionLevel: Int32   // -1 = default, 0 = store, 1...9
    public var smartStore: Bool          // 圧縮済み拡張子は自動 store（無駄な DEFLATE を避ける）

    public init(password: String? = nil,
                encryption: ZipEncryption = .zipCrypto,
                compressionLevel: Int32 = -1,
                smartStore: Bool = true) {
        self.password = password
        self.encryption = encryption
        self.compressionLevel = compressionLevel
        self.smartStore = smartStore
    }
    var effectivePassword: String? {
        guard encryption != .none, let p = password, !p.isEmpty else { return nil }
        return p
    }
    var useAES: Bool { encryption == .aes256 }
}

public enum CleanZipError: LocalizedError {
    case nothingToArchive
    case openFailed(URL)
    case writeFailed(URL)
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .nothingToArchive:   return "圧縮対象がありません。"
        case .openFailed(let u):  return "アーカイブを作成できませんでした: \(u.lastPathComponent)"
        case .writeFailed(let u): return "ファイルの書き込みに失敗しました: \(u.lastPathComponent)"
        case .cancelled:          return "キャンセルされました。"
        }
    }
}

/// 書き込み進捗のスナップショット。`completedFiles`/`completedBytes` は
/// 現在書き込み中のファイルを含まない（= 書き終えた分）。`currentName` は
/// これから/書き込み中のファイルの zip 内パス（完了時は空）。
public struct CleanZipProgress {
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let completedFiles: Int
    public let totalFiles: Int
    public let currentName: String

    /// 0...1。総バイトが 0（空）なら 1 とみなす。
    public var fraction: Double {
        totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 1
    }
}

public enum CleanZip {

    /// アーカイブに絶対入れない名前
    static func isJunk(_ name: String) -> Bool {
        if name == ".DS_Store"       { return true }
        if name.hasPrefix("._")      { return true }   // AppleDouble
        if name == "__MACOSX"        { return true }
        if name == ".AppleDouble"    { return true }
        if name == ".Spotlight-V100" { return true }
        if name == ".Trashes"        { return true }
        if name == ".fseventsd"      { return true }
        if name == ".TemporaryItems" { return true }
        if name == ".apdisk"         { return true }
        return false
    }

    /// すでに圧縮済みで、再 DEFLATE しても縮まない（時間だけ食う）拡張子（小文字）。
    /// smart-store はこれらを store(0) で書き、無駄な圧縮を避ける（サイズ同・大幅高速）。
    /// PDF は無圧縮ストリームを含む個体があるため意図的に除外（DESIGN.md §5 / smart-store 決定）。
    static let precompressedExtensions: Set<String> = [
        // 画像（非可逆 / 可逆問わず圧縮済み）
        "jpg", "jpeg", "jpe", "png", "gif", "webp", "heic", "heif", "avif", "jp2", "jxl",
        // 動画
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv",
        "mpg", "mpeg", "3gp", "3g2", "m2ts", "mts", "ts",
        // 音声
        "mp3", "m4a", "aac", "ogg", "oga", "opus", "flac", "wma", "ac3",
        // アーカイブ / 圧縮ストリーム
        "zip", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "7z", "rar", "zst", "zstd",
        "lz", "lz4", "lzma", "br", "cab", "z", "sit", "sitx", "arj", "lzh", "lha",
        // zip コンテナ系（Office OOXML / ODF / Java / モバイル / 拡張パッケージ）
        "docx", "docm", "xlsx", "xlsm", "pptx", "pptm",
        "odt", "ods", "odp", "odg",
        "epub", "jar", "war", "ear", "apk", "aab", "ipa", "aar",
        "xpi", "crx", "vsix", "nupkg", "whl", "kmz", "3mf",
        // 圧縮ディスクイメージ / 圧縮フォント
        "dmg", "woff", "woff2",
    ]

    /// 拡張子が「圧縮済み」セットに含まれるか（大文字小文字を無視）。
    static func isPrecompressed(_ ext: String) -> Bool {
        !ext.isEmpty && precompressedExtensions.contains(ext.lowercased())
    }

    /// zip に書き込む1ファイル（列挙フェーズで確定）。size は進捗の総量計算用。
    private struct PlanItem { let url: URL; let zipPath: String; let size: Int64 }

    /// items をまとめて destination にクリーン ZIP 化。各トップレベル項目は
    /// 自身の名前で zip 内に入る（フォルダはそのまま展開される＝Finder の Compress と同じ形）。
    ///
    /// 進捗とキャンセルは任意。先に対象ファイルを列挙して総量を確定し、ファイル境界ごとに
    /// `progress` を呼ぶ（SSZipArchive はファイル内途中経過を出せないため境界粒度）。
    /// `isCancelled` が true を返すと各ファイルの前で `CleanZipError.cancelled` を投げる。
    public static func make(items: [URL],
                            to destination: URL,
                            options: CleanZipOptions = .init(),
                            progress: ((CleanZipProgress) -> Void)? = nil,
                            isCancelled: (() -> Bool)? = nil) throws {
        let fm = FileManager.default
        let inputs = items.filter { !isJunk($0.lastPathComponent) }
        guard !inputs.isEmpty else { throw CleanZipError.nothingToArchive }

        // 1) 列挙フェーズ: 1回のツリー走査でジャンクを除外し、書き込む順にプランを作る。
        //    firmlink 差を避けるため zip 内パスはトップ項目名を起点に自前で組み立てる。
        var plan: [PlanItem] = []
        for item in inputs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                try collect(item, zipPrefix: item.lastPathComponent + "/", into: &plan, fm: fm)
            } else {
                plan.append(PlanItem(url: item, zipPath: item.lastPathComponent, size: fileSize(item, fm)))
            }
        }

        let totalBytes = plan.reduce(Int64(0)) { $0 + $1.size }
        let totalFiles = plan.count

        // 2) 書き込みフェーズ
        let archive = SSZipArchive(path: destination.path)
        guard archive.open() else { throw CleanZipError.openFailed(destination) }
        defer { archive.close() }

        var doneBytes: Int64 = 0
        for (i, p) in plan.enumerated() {
            if isCancelled?() == true { throw CleanZipError.cancelled }
            progress?(CleanZipProgress(completedBytes: doneBytes, totalBytes: totalBytes,
                                       completedFiles: i, totalFiles: totalFiles, currentName: p.zipPath))
            try writeFile(p, to: archive, options: options)
            doneBytes += p.size
        }
        progress?(CleanZipProgress(completedBytes: doneBytes, totalBytes: totalBytes,
                                   completedFiles: totalFiles, totalFiles: totalFiles, currentName: ""))
    }

    /// 元の隣に "<name>.zip"（重複は連番）
    public static func suggestedDestination(for items: [URL]) -> URL? {
        guard let first = items.first else { return nil }
        let dir = first.deletingLastPathComponent()
        let base = (items.count == 1)
            ? first.deletingPathExtension().lastPathComponent
            : "Archive"
        return uniqueURL(dir.appendingPathComponent(base).appendingPathExtension("zip"))
    }

    /// dir 配下を再帰し、ジャンクを除いた *ファイル* だけを zipPrefix 付きでプランに積む。
    /// 空ディレクトリと __MACOSX 等のジャンクディレクトリには潜らない（= 構造的にクリーン）。
    /// enumerator の絶対パス切り出しは /var→/private/var（APFS firmlink）でズレるため使わない。
    private static func collect(_ dir: URL, zipPrefix: String,
                                into plan: inout [PlanItem], fm: FileManager) throws {
        let children = try fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [])
        for child in children {
            let name = child.lastPathComponent
            if isJunk(name) { continue }
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let zipPath = zipPrefix + name
            if isDir {
                try collect(child, zipPrefix: zipPath + "/", into: &plan, fm: fm)
            } else {
                plan.append(PlanItem(url: child, zipPath: zipPath, size: fileSize(child, fm)))
            }
        }
    }

    private static func writeFile(_ item: PlanItem, to archive: SSZipArchive,
                                  options: CleanZipOptions) throws {
        // smart-store: 圧縮済み拡張子は DEFLATE を飛ばして store(0)。それ以外は指定レベル。
        let level = (options.smartStore && isPrecompressed(item.url.pathExtension))
            ? 0 : options.compressionLevel
        let ok = archive.writeFile(atPath: item.url.path,
                                   withFileName: item.zipPath,
                                   compressionLevel: level,
                                   password: options.effectivePassword,
                                   aes: options.useAES)
        if !ok { throw CleanZipError.writeFailed(item.url) }
    }

    private static func fileSize(_ url: URL, _ fm: FileManager) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    private static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while true {
            let c = dir.appendingPathComponent("\(stem) \(i)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: c.path) { return c }
            i += 1
        }
    }
}
