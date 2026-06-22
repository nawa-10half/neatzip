import SwiftUI
import AppKit

/// 設定画面（⌘,）。既定の暗号化・圧縮・出力先・右クリック挙動を UserDefaults に保存する。
struct SettingsView: View {
    @AppStorage(SettingsKey.defaultEncryption) private var enc = DefaultEncryption.none.rawValue
    @AppStorage(SettingsKey.compressionPreset) private var preset = CompressionPreset.standard.rawValue
    // 出力先の設定は Developer ID 版のみ（MAS は常に保存パネル＝この2つは使わない）。
    #if !MAS
    @AppStorage(SettingsKey.outputLocation)    private var output = OutputLocation.besideSource.rawValue
    @AppStorage(SettingsKey.fixedFolderPath)   private var fixedFolder = ""
    #endif
    @AppStorage(SettingsKey.promptEachTime)    private var promptEachTime = true

    var body: some View {
        Form {
            Picker("settings.defaultEncryption", selection: $enc) {
                ForEach(DefaultEncryption.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("settings.compression", selection: $preset) {
                ForEach(CompressionPreset.allCases) { Text($0.label).tag($0.rawValue) }
            }

            // 出力先の選択は Developer ID 版のみ。MAS 版は常に保存パネルなので出さない（DESIGN §12）。
            #if !MAS
            Picker("settings.output", selection: $output) {
                ForEach(OutputLocation.allCases) { Text($0.label).tag($0.rawValue) }
            }
            if output == OutputLocation.fixedFolder.rawValue {
                HStack {
                    Text(fixedFolder.isEmpty ? String(localized: "settings.notSelected") : fixedFolder)
                        .lineLimit(1).truncationMode(.head)
                        .foregroundStyle(fixedFolder.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("settings.chooseEllipsis", action: chooseFolder)
                }
            }

            Divider()
            #endif

            Toggle("settings.promptEachTime", isOn: $promptEachTime)
            if !promptEachTime && enc != DefaultEncryption.none.rawValue {
                Text("settings.caption.needsPassword")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !promptEachTime {
                Text("settings.caption.quick")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    #if !MAS
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "common.choose")
        if panel.runModal() == .OK, let url = panel.url { fixedFolder = url.path }
    }
    #endif
}
