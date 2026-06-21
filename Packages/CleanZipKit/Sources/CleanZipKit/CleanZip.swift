import Foundation
import CommonCrypto      // PBKDF2（AES 鍵導出を並列phaseで実施）
import Clibdeflate       // libdeflate 1.25: raw deflate 圧縮 + crc32
import Cminizip          // minizip-ng 4.2.1 + NeatZip パッチ: zip コンテナ + AES/PKCrypt

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
    /// 内部はファイル間並列で libdeflate 圧縮（CPU 律速をマルチコア化）し、その後 minizip の
    /// raw entry へ順次書き込む。進捗・キャンセルは書き込みフェーズのファイル境界で報告する
    /// （並列圧縮はコールバックを出さない＝従来と同じ「ファイル境界粒度・単調増加」を維持）。
    public static func make(items: [URL],
                            to destination: URL,
                            options: CleanZipOptions = .init(),
                            progress: ((CleanZipProgress) -> Void)? = nil,
                            isCancelled: (() -> Bool)? = nil) throws {
        let fm = FileManager.default
        let inputs = items.filter { !isJunk($0.lastPathComponent) }
        guard !inputs.isEmpty else { throw CleanZipError.nothingToArchive }

        // 1) 列挙フェーズ: 1回のツリー走査でジャンクを除外し、書き込む順にプランを作る。
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

        if isCancelled?() == true { throw CleanZipError.cancelled }

        // 2) 圧縮フェーズ（ファイル間並列・コールバック無し）
        //    各 distinct インデックスへの書き込みなので withUnsafeMutableBufferPointer で安全に並列化。
        var compressed = [CompressedEntry?](repeating: nil, count: totalFiles)
        if totalFiles > 0 {
            compressed.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: totalFiles) { i in
                    buf[i] = compressOne(plan[i], options: options)
                }
            }
        }

        // 3) 書き込みフェーズ（順次 raw write・進捗とキャンセルはここで）
        var streamVar: UnsafeMutableRawPointer? = mz_stream_os_create()
        guard streamVar != nil else { throw CleanZipError.openFailed(destination) }
        let stream = streamVar!
        guard mz_stream_os_open(stream, destination.path, MZ_OPEN_MODE_WRITE | MZ_OPEN_MODE_CREATE) == MZ_OK else {
            mz_stream_os_delete(&streamVar)
            throw CleanZipError.openFailed(destination)
        }
        var zipVar: UnsafeMutableRawPointer? = mz_zip_create()
        guard zipVar != nil else {
            mz_stream_os_close(stream); mz_stream_os_delete(&streamVar)
            throw CleanZipError.openFailed(destination)
        }
        let zip = zipVar!
        guard mz_zip_open(zip, stream, MZ_OPEN_MODE_WRITE) == MZ_OK else {
            mz_zip_delete(&zipVar); mz_stream_os_close(stream); mz_stream_os_delete(&streamVar)
            throw CleanZipError.openFailed(destination)
        }
        // 途中 throw（キャンセル等）でも CD を閉じて解放する。部分 zip の削除は呼び出し側責務。
        defer {
            mz_zip_close(zip)
            mz_zip_delete(&zipVar)
            mz_stream_os_close(stream)
            mz_stream_os_delete(&streamVar)
        }

        var doneBytes: Int64 = 0
        for (i, p) in plan.enumerated() {
            if isCancelled?() == true { throw CleanZipError.cancelled }
            progress?(CleanZipProgress(completedBytes: doneBytes, totalBytes: totalBytes,
                                       completedFiles: i, totalFiles: totalFiles, currentName: p.zipPath))
            guard let entry = compressed[i] else { throw CleanZipError.writeFailed(p.url) }
            try writeEntry(entry, to: zip, options: options)
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

    // MARK: - エンジン（libdeflate 圧縮 → minizip raw write）

    /// 圧縮済み1エントリ。書き込みフェーズに渡す中間表現。
    private final class CompressedEntry {
        let zipPath: String
        let method: Int32          // MZ_COMPRESS_METHOD_*
        let payload: [UInt8]       // deflate 出力 or（store時）生バイト
        let crc: UInt32
        let usize: Int64           // 非圧縮サイズ
        let mtime: time_t
        let salt: [UInt8]          // AES のみ（並列導出）。それ以外は空
        let kbuf: [UInt8]          // AES のみ（[aes32|hmac32|verify2]）。それ以外は空
        init(zipPath: String, method: Int32, payload: [UInt8], crc: UInt32,
             usize: Int64, mtime: time_t, salt: [UInt8], kbuf: [UInt8]) {
            self.zipPath = zipPath; self.method = method; self.payload = payload
            self.crc = crc; self.usize = usize; self.mtime = mtime
            self.salt = salt; self.kbuf = kbuf
        }
    }

    /// 1ファイルを読み込み libdeflate で圧縮、必要なら AES 鍵をその場（並列phase）で導出する。
    /// 失敗時は nil（書き込みフェーズで .writeFailed を投げる）。
    private static func compressOne(_ item: PlanItem, options: CleanZipOptions) -> CompressedEntry? {
        guard let data = FileManager.default.contents(atPath: item.url.path) else { return nil }
        let input = [UInt8](data)
        let n = input.count

        let crc: UInt32 = input.withUnsafeBytes { libdeflate_crc32(0, $0.baseAddress, n) }

        // smart-store / レベル決定。0 = store。
        let store = (options.smartStore && isPrecompressed(item.url.pathExtension))
            || options.compressionLevel == 0 || n == 0
        let level: Int32 = options.compressionLevel < 0 ? 6 : options.compressionLevel

        var method = MZ_COMPRESS_METHOD_STORE
        var payload = input
        if !store, let comp = libdeflate_alloc_compressor(level) {
            defer { libdeflate_free_compressor(comp) }
            let bound = libdeflate_deflate_compress_bound(comp, n)
            var out = [UInt8](repeating: 0, count: bound)
            let clen = out.withUnsafeMutableBytes { dst in
                input.withUnsafeBytes { src in
                    libdeflate_deflate_compress(comp, src.baseAddress, n, dst.baseAddress, bound)
                }
            }
            if clen > 0 && clen < n {
                out.removeLast(bound - clen)
                method = MZ_COMPRESS_METHOD_DEFLATE
                payload = out
            }
        }

        // AES: salt 生成 + PBKDF2 鍵導出を並列phaseで（逐次 write の高コストを排する）
        var salt = [UInt8](); var kbuf = [UInt8]()
        if options.useAES, let pw = options.effectivePassword {
            salt = [UInt8](repeating: 0, count: 16)
            arc4random_buf(&salt, 16)
            kbuf = [UInt8](repeating: 0, count: 66)   // [aes_key32 | hmac_key32 | verify2]
            _ = pw.withCString { pwPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwPtr, strlen(pwPtr),
                                     salt, 16, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                     1000, &kbuf, 66)
            }
        }

        let mtime = (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate.map { time_t($0.timeIntervalSince1970) } ?? time(nil)
        return CompressedEntry(zipPath: item.zipPath, method: method, payload: payload,
                               crc: crc, usize: Int64(n), mtime: mtime, salt: salt, kbuf: kbuf)
    }

    /// 圧縮済みエントリを minizip の raw entry として書き込む。
    private static func writeEntry(_ e: CompressedEntry, to zip: UnsafeMutableRawPointer,
                                   options: CleanZipOptions) throws {
        var fi = mz_zip_file()
        fi.version_madeby = UInt16(MZ_HOST_SYSTEM_UNIX) << 8
        fi.compression_method = UInt16(e.method)
        fi.modified_date = e.mtime
        fi.flag = UInt16(MZ_ZIP_FLAG_UTF8)
        fi.uncompressed_size = e.usize
        fi.compressed_size = Int64(e.payload.count)
        fi.crc = e.crc
        fi.external_fa = UInt32(0o100644) << 16   // regular file rw-r--r--

        let password = options.effectivePassword
        if password != nil {
            fi.flag |= UInt16(MZ_ZIP_FLAG_ENCRYPTED)
            if options.useAES {
                fi.aes_version = UInt16(MZ_AES_VERSION)
                fi.aes_strength = UInt8(MZ_AES_STRENGTH_256)
                // 並列導出済みの鍵を注入 → このエントリの PBKDF2 を minizip がスキップ
                mz_zip_set_aes_key(zip, e.salt, 16, e.kbuf, 66)
            }
        }

        let level = Int16(options.compressionLevel < 0 ? 6 : max(0, options.compressionLevel))
        let rc: Int32 = e.zipPath.withCString { namePtr -> Int32 in
            fi.filename = namePtr
            func withPwd<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
                if let p = password { return p.withCString { body($0) } } else { return body(nil) }
            }
            return withPwd { pwPtr in
                if mz_zip_entry_write_open(zip, &fi, level, 1, pwPtr) != MZ_OK { return -1 }
                if !e.payload.isEmpty {
                    let w = e.payload.withUnsafeBytes {
                        mz_zip_entry_write(zip, $0.baseAddress, Int32(e.payload.count))
                    }
                    if w < 0 { return -1 }
                }
                return mz_zip_entry_close_raw(zip, e.usize, e.crc)
            }
        }
        if rc != MZ_OK { throw CleanZipError.writeFailed(URL(fileURLWithPath: e.zipPath)) }
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
