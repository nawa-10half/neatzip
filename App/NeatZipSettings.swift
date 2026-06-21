import Foundation
import CleanZipKit

/// UserDefaults のキー（SwiftUI の @AppStorage と AppKit 側で共有）。
enum SettingsKey {
    static let defaultEncryption = "defaultEncryption"
    static let compressionPreset = "compressionPreset"
    static let outputLocation    = "outputLocation"
    static let fixedFolderPath   = "fixedFolderPath"
    static let promptEachTime    = "promptEachTime"
}

/// 既定の暗号化方式。`ZipEncryption` に対応。
enum DefaultEncryption: String, CaseIterable, Identifiable {
    case none, zipCrypto, aes256
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:      return String(localized: "enc.none")
        case .zipCrypto: return String(localized: "enc.zipcrypto.long")
        case .aes256:    return String(localized: "enc.aes.long")
        }
    }
    var zipEncryption: ZipEncryption {
        switch self {
        case .none:      return .none
        case .zipCrypto: return .zipCrypto
        case .aes256:    return .aes256
        }
    }
    /// パスワード入力が要る方式か（要る場合は右クリック時に必ず確認ダイアログを出す）。
    var needsPassword: Bool { self != .none }
}

/// 圧縮プリセット（libdeflate レベルへ写像）。生の数値はユーザーに見せない。
enum CompressionPreset: String, CaseIterable, Identifiable {
    case standard, fast, small
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: return String(localized: "comp.standard")
        case .fast:     return String(localized: "comp.fast")
        case .small:    return String(localized: "comp.small")
        }
    }
    var level: Int32 {
        switch self {
        case .standard: return 6
        case .fast:     return 1
        case .small:    return 9
        }
    }
}

/// 出力先の決め方。
enum OutputLocation: String, CaseIterable, Identifiable {
    case besideSource, ask, fixedFolder
    var id: String { rawValue }
    var label: String {
        switch self {
        case .besideSource: return String(localized: "out.beside")
        case .ask:          return String(localized: "out.ask")
        case .fixedFolder:  return String(localized: "out.fixed")
        }
    }
}

/// 永続化された設定の読み出し（AppKit 側＝ZipController 用）。書き込みは SettingsView の @AppStorage。
enum NeatZipSettings {
    private static var d: UserDefaults { .standard }

    static var defaultEncryption: DefaultEncryption {
        DefaultEncryption(rawValue: d.string(forKey: SettingsKey.defaultEncryption) ?? "") ?? .none
    }
    static var compressionPreset: CompressionPreset {
        CompressionPreset(rawValue: d.string(forKey: SettingsKey.compressionPreset) ?? "") ?? .standard
    }
    static var outputLocation: OutputLocation {
        OutputLocation(rawValue: d.string(forKey: SettingsKey.outputLocation) ?? "") ?? .besideSource
    }
    static var fixedFolderPath: String? {
        let p = d.string(forKey: SettingsKey.fixedFolderPath)
        return (p?.isEmpty ?? true) ? nil : p
    }
    /// 右クリック時に毎回オプションダイアログを出すか（既定 true＝現行挙動）。
    static var promptEachTime: Bool {
        d.object(forKey: SettingsKey.promptEachTime) == nil ? true : d.bool(forKey: SettingsKey.promptEachTime)
    }
    static var compressionLevel: Int32 { compressionPreset.level }
}
