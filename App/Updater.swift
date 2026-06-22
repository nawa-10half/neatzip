// Sparkle は Developer ID 版のみ（MAS は自己更新フレームワーク同梱不可）。MAS ターゲットは
// Sparkle を依存に含めないため `canImport(Sparkle)` が false になり、このファイルは丸ごと除外される。
#if canImport(Sparkle)
import SwiftUI
import Sparkle

// 自動アップデート（Sparkle 2）。Developer ID 直配布のため採用（DESIGN §14）。
// ネスト XPC/ヘルパーの Developer ID 再署名は scripts/release.sh が担当（§10）。

/// アプリ全体で共有する Sparkle updater。
/// handoff 起動（neatzip://）は処理が終わると即終了するヘルパーなので updater を開始しない。
/// 対話起動（ドロップ窓 / "このアプリで開く"）のときだけ AppDelegate が `start()` を呼ぶ。
final class AppUpdater {
    static let shared = AppUpdater()

    let controller: SPUStandardUpdaterController
    private var started = false

    private init() {
        // startingUpdater:false ＝ 起動時に自動チェックを始めない。経路確定後に start() で開始する。
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// 対話起動のときだけ呼ぶ。多重起動は無視する。
    func start() {
        guard !started else { return }
        started = true
        controller.startUpdater()   // 自動チェックのスケジュールを開始する
    }

    var updater: SPUUpdater { controller.updater }
}

/// メニューの「アップデートを確認…」項目。`canCheckForUpdates` に追従して有効/無効を切り替える。
/// （Monterey 以前で disabled 状態を正しく反映させるため、専用 View を挟むのが Sparkle 推奨。）
struct CheckForUpdatesCommand: View {
    @StateObject private var model: CheckForUpdatesModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _model = StateObject(wrappedValue: CheckForUpdatesModel(updater: updater))
    }

    var body: some View {
        Button("menu.checkForUpdates") { updater.checkForUpdates() }
            .disabled(!model.canCheckForUpdates)
    }
}

/// updater がチェック可能かを publish する（メニュー項目の有効化に使う）。
private final class CheckForUpdatesModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}
#endif
