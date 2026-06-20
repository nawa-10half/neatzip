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
        // 本体 = .../NeatZip.app/Contents/PlugIns/Ext.appex → 3 階層上
        let host = Bundle.main.bundleURL
            .deletingLastPathComponent()   // PlugIns
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // .app
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: host, configuration: cfg) { _, error in
            if let error { NSLog("NeatZip handoff failed: \(error)") }
        }
    }
}
