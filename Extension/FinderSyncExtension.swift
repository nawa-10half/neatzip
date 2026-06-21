import Cocoa
import FinderSync

final class FinderSyncExtension: FIFinderSync {

    override init() {
        super.init()
        // コンテキストメニュー用途。selectedItemURLs は監視対象配下でしか出ないので、
        // マウント済みボリュームを広く claim して「どこでも」出るようにする（バッジ無しなので低コスト）。
        let controller = FIFinderSyncController.default()
        if let vols = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: []) {
            controller.directoryURLs = Set(vols)
        }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        guard menuKind == .contextualMenuForItems else { return menu }
        let item = NSMenuItem(title: "NeatZip でクリーンZIP…",
                              action: #selector(cleanZip(_:)), keyEquivalent: "")
        if let icon = NSImage(named: "FinderMenuIcon") { item.image = icon }
        menu.addItem(item)
        return menu
    }

    @objc private func cleanZip(_ sender: AnyObject?) {
        guard let urls = FIFinderSyncController.default().selectedItemURLs(),
              !urls.isEmpty else { return }
        // サンドボックス拡張は Finder 選択 file URL のアクセス権を本体へ移譲できない。
        // よって選択パスを独自スキーム neatzip:// に積んで本体（非サンドボックス）へ渡し、
        // 本体が自前でファイルを読む。URL を開くだけなのでサンドボックスで許可される。
        var comps = URLComponents()
        comps.scheme = "neatzip"
        comps.host = "zip"
        comps.queryItems = urls.map { URLQueryItem(name: "p", value: $0.path) }
        guard let url = comps.url else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(url, configuration: cfg) { _, error in
            if let error { NSLog("NeatZip handoff failed: \(error)") }
        }
    }
}
