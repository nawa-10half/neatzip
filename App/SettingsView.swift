import SwiftUI
import AppKit

/// 設定画面（⌘,）。既定の暗号化・圧縮・出力先・右クリック挙動を UserDefaults に保存する。
struct SettingsView: View {
    @AppStorage(SettingsKey.defaultEncryption) private var enc = DefaultEncryption.none.rawValue
    @AppStorage(SettingsKey.compressionPreset) private var preset = CompressionPreset.standard.rawValue
    @AppStorage(SettingsKey.outputLocation)    private var output = OutputLocation.besideSource.rawValue
    @AppStorage(SettingsKey.fixedFolderPath)   private var fixedFolder = ""
    @AppStorage(SettingsKey.promptEachTime)    private var promptEachTime = true

    var body: some View {
        Form {
            Picker("既定の暗号化", selection: $enc) {
                ForEach(DefaultEncryption.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("圧縮", selection: $preset) {
                ForEach(CompressionPreset.allCases) { Text($0.label).tag($0.rawValue) }
            }

            Picker("出力先", selection: $output) {
                ForEach(OutputLocation.allCases) { Text($0.label).tag($0.rawValue) }
            }
            if output == OutputLocation.fixedFolder.rawValue {
                HStack {
                    Text(fixedFolder.isEmpty ? "（未選択）" : fixedFolder)
                        .lineLimit(1).truncationMode(.head)
                        .foregroundStyle(fixedFolder.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("選択…", action: chooseFolder)
                }
            }

            Divider()

            Toggle("右クリック時に毎回オプションを確認", isOn: $promptEachTime)
            if !promptEachTime && enc != DefaultEncryption.none.rawValue {
                Text("暗号化を使う設定ではパスワード入力が必要なため、毎回確認します。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !promptEachTime {
                Text("右クリックで即座にクリーンZIPを作成します（暗号化なし）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選択"
        if panel.runModal() == .OK, let url = panel.url { fixedFolder = url.path }
    }
}
