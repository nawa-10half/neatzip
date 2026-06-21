import AppKit

/// 初回起動時に Finder 拡張の有効化方法を案内する（§11）。
enum Onboarding {
    private static let shownKey = "NeatZipOnboardingShown"

    static func showIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: shownKey) else { return }
        defaults.set(true, forKey: shownKey)

        let alert = NSAlert()
        alert.messageText = "NeatZip へようこそ"
        alert.informativeText = """
        Finder の右クリックメニューから「クリーンZIP」を使うには、Finder 拡張を有効にしてください。

        システム設定 →「一般」→「ログイン項目と機能拡張」→「機能拡張」→「Finder 拡張機能」で NeatZip を ON にします。

        （ドラッグ&ドロップは、このウインドウにファイル／フォルダを落とすだけで使えます）
        """
        alert.addButton(withTitle: "システム設定を開く")
        alert.addButton(withTitle: "あとで")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(url)
        }
    }
}
