import SwiftUI

@main
struct NeatZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { DropView() }
            .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var handledOpen = false
    /// 右クリック（neatzip:// handoff）起動か。ドロップ窓を見せず、完了後に終了する。
    private var isHandoff = false

    // Finder 拡張（独自スキーム neatzip://）/ "このアプリで開く"（file URL）から対象を受信。
    func application(_ application: NSApplication, open urls: [URL]) {
        handledOpen = true
        // Finder 右クリック（neatzip:// handoff）で起動した場合は一回限りのヘルパーとして
        // 完了後に終了する。"このアプリで開く"（file URL）やドロップ窓の対話利用では終了しない。
        let fromHandoff = urls.contains { $0.scheme == "neatzip" }
        if fromHandoff {
            isHandoff = true
            hideDropWindows()   // 右クリック起動はドロップ窓を見せない
        }
        let items = urls.flatMap { url -> [URL] in
            if url.isFileURL { return [url] }                       // "このアプリで開く" / ドロップ経由
            if url.scheme == "neatzip" { return Self.itemURLs(from: url) }  // Finder 拡張の handoff
            return []
        }
        guard !items.isEmpty else {
            if fromHandoff { NSApp.terminate(nil) }
            return
        }
        DispatchQueue.main.async { ZipController.shared.begin(with: items, quitWhenDone: fromHandoff) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 起動経路が確定するまでドロップ窓を伏せておく（透明化＋order out）。右クリック起動なら
        // 一度も見せずに済む＝チラつきゼロ。SwiftUI が後から窓を出すケースに備え、
        // ウィンドウ生成も監視して handoff 中は伏せ続ける（進捗パネル＝NSPanel は対象外）。
        hideDropWindows()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)

        // openURLs（neatzip:// / file URL）は起動直後に届く。少し待って経路を見極め、
        // handoff でなければドロップ窓を出す。直接起動の初回のみ拡張有効化を案内する。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.isHandoff else { return }   // handoff は伏せたまま終了する
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didBecomeKeyNotification, object: nil)
            self.showDropWindows()
            if !self.handledOpen { Onboarding.showIfNeeded() }
        }
    }

    /// handoff 中に SwiftUI がドロップ窓を出してきたら即伏せる。進捗パネルやダイアログ
    /// （いずれも NSPanel）には触れない。
    @objc private func windowDidBecomeKey(_ note: Notification) {
        guard isHandoff, let w = note.object as? NSWindow, !(w is NSPanel) else { return }
        w.alphaValue = 0
        w.orderOut(nil)
    }

    // MARK: - ドロップ窓（SwiftUI WindowGroup のウィンドウ）の表示制御

    /// 進捗パネル等（NSPanel）を除いた、本体のウィンドウ群。
    private func dropWindows() -> [NSWindow] { NSApp.windows.filter { !($0 is NSPanel) } }

    private func hideDropWindows() {
        for w in dropWindows() { w.alphaValue = 0; w.orderOut(nil) }
    }

    private func showDropWindows() {
        let ws = dropWindows()
        for w in ws { w.alphaValue = 1 }
        ws.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// neatzip://zip?p=<path>&p=<path>... を file URL 配列へ復元する
    private static func itemURLs(from url: URL) -> [URL] {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        return (comps.queryItems ?? [])
            .filter { $0.name == "p" }
            .compactMap { $0.value }
            .map { URL(fileURLWithPath: $0) }
    }
}
