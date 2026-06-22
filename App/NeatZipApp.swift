import SwiftUI

@main
struct NeatZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { DropView() }
            .windowResizability(.contentSize)
            .commands {
                // アプリメニュー「NeatZip について」の直後に「アップデートを確認…」を置く（§14）。
                // Sparkle は Developer ID 版のみ。MAS 版（Sparkle 非リンク）ではこの項目を出さない。
                #if canImport(Sparkle)
                CommandGroup(after: .appInfo) {
                    CheckForUpdatesCommand(updater: AppUpdater.shared.updater)
                }
                #endif
            }
        Settings { SettingsView() }   // ⌘, ＝既定の暗号化/圧縮/出力先（DESIGN §14）
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var handledOpen = false
    /// Finder 右クリック（macOS Services）で起動したか。ドロップ窓を見せず、完了後に終了する。
    private var isHandoff = false
    /// 通常（対話）起動でドロップ窓を表示済みか。サービス呼び出しをワンショット扱いするか判定する。
    private var didBecomeInteractive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Finder 右クリック「NeatZip でクリーンZIP」(Info.plist の NSServices) のハンドラを登録。
        NSApp.servicesProvider = self

        // 起動経路が確定するまでドロップ窓を伏せておく（透明化＋order out）。サービス起動なら
        // 一度も見せずに済む＝チラつきゼロ。SwiftUI が後から窓を出すケースに備え、ウィンドウ生成も
        // 監視してワンショット中は伏せ続ける（進捗パネル＝NSPanel は対象外）。
        hideDropWindows()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)

        // サービス（cleanZip:）/ 開く要求は起動直後に届く。少し待って経路を見極め、ワンショット
        // でなければドロップ窓を出す。対話起動の初回のみオンボーディングを案内する。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.isHandoff else { return }   // サービス起動は伏せたまま終了する
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didBecomeKeyNotification, object: nil)
            self.showDropWindows()
            self.didBecomeInteractive = true
            #if canImport(Sparkle)
            AppUpdater.shared.start()   // 対話起動のときだけ自動アップデートを開始（ワンショットは終了済み）
            #endif
            if !self.handledOpen { Onboarding.showIfNeeded() }
        }
    }

    /// 「このアプリで開く」/ Dock アイコンへのドロップ（file URL）。対話利用なので完了後も終了しない。
    func application(_ application: NSApplication, open urls: [URL]) {
        let items = urls.filter { $0.isFileURL }
        guard !items.isEmpty else { return }
        handledOpen = true
        DispatchQueue.main.async { ZipController.shared.begin(with: items, quitWhenDone: false) }
    }

    // MARK: - Finder 右クリック（macOS Services「NeatZip でクリーンZIP」）

    /// Info.plist の NSServices（NSMessage = cleanZip）から呼ばれる。選択されたファイル/フォルダを
    /// pasteboard で受け取り、本体（非サンドボックス）が直接 ZIP 化する。まだ対話状態に入っていない
    /// ＝サービスで起動された場合はワンショットとして完了後に終了し、ドロップ窓は一度も見せない。
    @objc func cleanZip(_ pboard: NSPasteboard, userData: String?,
                        error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let items = (pboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]) ?? []
        guard !items.isEmpty else { return }
        handledOpen = true
        let oneShot = !didBecomeInteractive
        if oneShot {
            isHandoff = true
            hideDropWindows()
        }
        NSApp.activate(ignoringOtherApps: true)   // 進捗パネル/オプションダイアログを前面に出す
        DispatchQueue.main.async { ZipController.shared.begin(with: items, quitWhenDone: oneShot) }
    }

    /// ワンショット（サービス）中に SwiftUI がドロップ窓を出してきたら即伏せる。進捗パネルや
    /// ダイアログ（いずれも NSPanel）には触れない。
    @objc private func windowDidBecomeKey(_ note: Notification) {
        guard isHandoff, let w = note.object as? NSWindow, isDropWindow(w) else { return }
        hide(w)
    }

    // MARK: - ドロップ窓（SwiftUI WindowGroup のウィンドウ）の表示制御

    /// ドロップ窓かどうか。本体の補助 UI（進捗パネル・各種ダイアログ）はすべて NSPanel なので、
    /// それ以外＝ドロップ窓とみなす。
    /// 設定ウィンドウ（Settings シーン・⌘,）は NSPanel ではないがこの判定に巻き込まれない:
    /// 表示制御は起動時のみ（observer は 0.5s 後に解除）で、設定窓はユーザーが起動後に開くため
    /// その時点では存在しない。ワンショットは設定を開く前に終了する。将来 launch 直後に出る
    /// 非 NSPanel ウィンドウを足す場合はここで明示除外すること。
    private func isDropWindow(_ w: NSWindow) -> Bool { !(w is NSPanel) }

    /// 補助 UI（NSPanel）を除いた、本体のドロップ窓群。
    private func dropWindows() -> [NSWindow] { NSApp.windows.filter { isDropWindow($0) } }

    private func hide(_ w: NSWindow) { w.alphaValue = 0; w.orderOut(nil) }

    private func hideDropWindows() { for w in dropWindows() { hide(w) } }

    private func showDropWindows() {
        let ws = dropWindows()
        for w in ws { w.alphaValue = 1 }
        ws.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
