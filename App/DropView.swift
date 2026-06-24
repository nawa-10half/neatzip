import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// ブランドの青（アイコン本体色 #427CF2・デザインシステムの `--accent`）。
/// ワードマークの "zip" とドロップゾーンのアクセントに使う。インタラクティブな
/// システムコントロールは macOS のアクセント（Color.accentColor）のままにして native 感を保つ。
private let nzAccent = Color(red: 0x42 / 255.0, green: 0x7C / 255.0, blue: 0xF2 / 255.0)

/// メインウインドウ。上部に neatzip ワードマーク＋設定ギア、下にドラッグ&ドロップ受け口。
/// 右クリック（Services）/「開く」/ D&D はいずれも ZipController.begin(with:) に集約される。
struct DropView: View {
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 18) {
            header
            dropZone
        }
        .padding(20)
        .frame(width: 460, height: 360)
    }

    // MARK: - ヘッダー（ブランド＋設定への入口）

    private var header: some View {
        HStack(spacing: 10) {
            // 実アプリアイコン（squircle 込み）をそのまま小さく使う＝専用アセット不要。
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 26, height: 26)
            // 二色ワードマーク: neat（ink）＋ zip（ブランド青）をスペースなしで詰める。
            HStack(spacing: 0) {
                Text("neat").foregroundColor(.primary).tracking(-0.5)
                Text("zip").foregroundColor(nzAccent).tracking(-0.5)
            }
            .font(.system(size: 22, weight: .heavy))
            Spacer()
            settingsButton
        }
    }

    private var gearIcon: some View {
        Image(systemName: "gearshape")
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(.secondary)
    }

    /// 設定（⌘,）への入口。macOS 14+ は公式の SettingsLink（応答チェーンに依存せず確実に開く）、
    /// 13 は showSettingsWindow: セレクタにフォールバックする。
    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { gearIcon }
                .buttonStyle(.plain)
                .help(Text("tooltip.settings"))
        } else {
            Button(action: openSettingsWindow) { gearIcon }
                .buttonStyle(.plain)
                .help(Text("tooltip.settings"))
        }
    }

    // MARK: - ドロップゾーン

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    hovering ? nzAccent : Color.secondary.opacity(0.5),
                    style: StrokeStyle(lineWidth: 2, dash: [7])
                )
            VStack(spacing: 10) {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(hovering ? nzAccent : .secondary)
                Text("drop.title")
                    .font(.system(size: 17, weight: .semibold))
                Text("drop.subtitle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onDrop(of: [.fileURL], isTargeted: $hovering) { providers in
            load(providers) { urls in
                guard !urls.isEmpty else { return }
                ZipController.shared.begin(with: urls)
            }
            return true
        }
    }

    // MARK: - 設定を開く

    /// 設定（⌘,）をボタンから開く。deploymentTarget 13 なので `showSettingsWindow:`（macOS 13+）を
    /// 使い、ハンドラ不在なら旧 `showPreferencesWindow:` にフォールバックする。
    private func openSettingsWindow() {
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    private func load(_ providers: [NSItemProvider], done: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(urls) }
    }
}
