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
    // Finder 拡張 / "このアプリで開く" から渡される URL を受信
    func application(_ application: NSApplication, open urls: [URL]) {
        DispatchQueue.main.async { ZipController.shared.begin(with: urls) }
    }
}
