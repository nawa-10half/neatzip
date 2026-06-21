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
    // Finder 拡張（独自スキーム neatzip://）/ "このアプリで開く"（file URL）から対象を受信
    func application(_ application: NSApplication, open urls: [URL]) {
        let items = urls.flatMap { url -> [URL] in
            if url.isFileURL { return [url] }                       // "このアプリで開く" / ドロップ経由
            if url.scheme == "neatzip" { return Self.itemURLs(from: url) }  // Finder 拡張の handoff
            return []
        }
        guard !items.isEmpty else { return }
        DispatchQueue.main.async { ZipController.shared.begin(with: items) }
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
