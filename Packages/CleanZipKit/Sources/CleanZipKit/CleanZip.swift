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

    public init(password: String? = nil,
                encryption: ZipEncryption = .zipCrypto,
                compressionLevel: Int32 = -1) {
        self.password = password
        self.encryption = encryption
        self.compressionLevel = compressionLevel
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
    public var errorDescription: String? {
        switch self {
        case .nothingToArchive:   return "圧縮対象がありません。"
        case .openFailed(let u):  return "アーカイブを作成できませんでした: \(u.lastPathComponent)"
        case .writeFailed(let u): return "ファイルの書き込みに失敗しました: \(u.lastPathComponent)"
        }
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

    /// items をまとめて destination にクリーン ZIP 化。各トップレベル項目は
    /// 自身の名前で zip 内に入る（フォルダはそのまま展開される＝Finder の Compress と同じ形）。
    public static func make(items: [URL],
                            to destination: URL,
                            options: CleanZipOptions = .init()) throws {
        let fm = FileManager.default
        let inputs = items.filter { !isJunk($0.lastPathComponent) }
        guard !inputs.isEmpty else { throw CleanZipError.nothingToArchive }

        let archive = SSZipArchive(path: destination.path)
        guard archive.open() else { throw CleanZipError.openFailed(destination) }
        defer { archive.close() }

        for item in inputs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                try addDirectory(item, to: archive, options: options, fm: fm)
            } else {
                try addFile(item, zipPath: item.lastPathComponent, to: archive, options: options)
            }
        }
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

    private static func addDirectory(_ dir: URL, to archive: SSZipArchive,
                                     options: CleanZipOptions, fm: FileManager) throws {
        // zip 内パスはトップ項目名を起点に「自前で組み立てる」。enumerator の絶対パス
        // 文字列を切り出す方式は /var→/private/var（APFS firmlink）の解決差でズレるため使わない。
        try addTree(dir, zipPrefix: dir.lastPathComponent + "/",
                    to: archive, options: options, fm: fm)
    }

    /// dir 配下を再帰し、ジャンクを除いた *ファイル* だけを zipPrefix 付きで追加する。
    /// 空ディレクトリと __MACOSX 等のジャンクディレクトリには潜らない（= 構造的にクリーン）。
    private static func addTree(_ dir: URL, zipPrefix: String, to archive: SSZipArchive,
                                options: CleanZipOptions, fm: FileManager) throws {
        let children = try fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        for child in children {
            let name = child.lastPathComponent
            if isJunk(name) { continue }
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let zipPath = zipPrefix + name
            if isDir {
                try addTree(child, zipPrefix: zipPath + "/", to: archive, options: options, fm: fm)
            } else {
                try addFile(child, zipPath: zipPath, to: archive, options: options)
            }
        }
    }

    private static func addFile(_ url: URL, zipPath: String,
                                to archive: SSZipArchive, options: CleanZipOptions) throws {
        let ok = archive.writeFile(atPath: url.path,
                                   withFileName: zipPath,
                                   compressionLevel: options.compressionLevel,
                                   password: options.effectivePassword,
                                   aes: options.useAES)
        if !ok { throw CleanZipError.writeFailed(url) }
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
